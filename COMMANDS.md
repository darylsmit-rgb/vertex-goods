# Commands outside Terraform

Terraform owns durable configuration. The commands below handle pod restarts,
runtime validation, audits, and troubleshooting.

Set the common values first:

```bash
export AWS_REGION='us-gov-west-1'
export MGMT_CLUSTER_NAME='<vertex-management-cluster>'
export WORKLOAD_CLUSTER_NAME='<vertex-deployed-eks-cluster>'
```

## Management-cluster validation

Confirm the agent add-on and DaemonSet:

```bash
aws eks describe-addon \
  --cluster-name "${MGMT_CLUSTER_NAME}" \
  --addon-name eks-pod-identity-agent \
  --region "${AWS_REGION}" \
  --query 'addon.{status:status,version:addonVersion}'

kubectl -n kube-system rollout status \
  daemonset/eks-pod-identity-agent --timeout=5m
```

Confirm the management-cluster associations:

```bash
aws eks list-pod-identity-associations \
  --cluster-name "${MGMT_CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --output table
```

Existing pods must be recreated after their association is created:

```bash
kubectl delete pods -n hubble-system -l app=spectro-hubble
kubectl delete pods -n palette-identity -l app=palette-identity
```

Verify EKS injected both credential-provider variables:

```bash
kubectl get pods -n hubble-system -l app=spectro-hubble \
  -o jsonpath='{.items[0].spec.containers[0].env[*].name}' |
  tr ' ' '\n' |
  grep AWS_CONTAINER

kubectl get pods -n palette-identity -l app=palette-identity \
  -o jsonpath='{.items[0].spec.containers[0].env[*].name}' |
  tr ' ' '\n' |
  grep AWS_CONTAINER
```

Expected:

```text
AWS_CONTAINER_CREDENTIALS_FULL_URI
AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE
```

## Workload-cluster validation

Update kubeconfig using an IAM user listed in the profile's `mapUsers`:

```bash
aws eks update-kubeconfig \
  --name "${WORKLOAD_CLUSTER_NAME}" \
  --region "${AWS_REGION}"
```

Confirm agent and associations:

```bash
aws eks describe-addon \
  --cluster-name "${WORKLOAD_CLUSTER_NAME}" \
  --addon-name eks-pod-identity-agent \
  --region "${AWS_REGION}" \
  --query 'addon.{status:status,version:addonVersion}'

kubectl -n kube-system rollout status \
  daemonset/eks-pod-identity-agent --timeout=5m

aws eks list-pod-identity-associations \
  --cluster-name "${WORKLOAD_CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --output table
```

Confirm each Linux node has an agent pod:

```bash
kubectl get nodes -o wide
kubectl -n kube-system get pods \
  -l app.kubernetes.io/name=eks-pod-identity-agent -o wide
```

## Validate an NLB Service

The optional `nlb_services` Terraform map creates a new Service with the NLB
annotation present from its first API request. Confirm the Service annotation
and hostname:

```bash
kubectl get service -n '<namespace>' '<service-name>' \
  -o jsonpath='{.metadata.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-type}{"\n"}{.status.loadBalancer.ingress[0].hostname}{"\n"}'
```

The first line must be `nlb`. Resolve the AWS resource and prove its type is
`network`:

```bash
nlb_hostname="$(kubectl get service -n '<namespace>' '<service-name>' \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"

aws elbv2 describe-load-balancers \
  --region "${AWS_REGION}" \
  --query "LoadBalancers[?DNSName=='${nlb_hostname}'].{Name:LoadBalancerName,Type:Type,Scheme:Scheme,State:State.Code}" \
  --output table
```

Do not change the load-balancer type annotation on an existing Classic Load
Balancer Service. AWS recommends recreating the Service with the correct
annotation to avoid leaked load balancers.

## Prove no IAM OIDC provider is associated

EKS always reports an issuer URL, even when no IAM OIDC provider exists. Compare
the cluster issuer with the URLs of registered IAM providers:

```bash
cluster_issuer="$({
  aws eks describe-cluster \
    --name "${WORKLOAD_CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --query 'cluster.identity.oidc.issuer' \
    --output text
})"
cluster_issuer="${cluster_issuer#https://}"

match_count=0
while read -r provider_arn; do
  [[ -n "${provider_arn}" ]] || continue
  provider_url="$({
    aws iam get-open-id-connect-provider \
      --open-id-connect-provider-arn "${provider_arn}" \
      --query 'Url' \
      --output text
  })"
  if [[ "${provider_url}" == "${cluster_issuer}" ]]; then
    printf 'MATCH: %s\n' "${provider_arn}"
    match_count=$((match_count + 1))
  fi
done < <(
  aws iam list-open-id-connect-providers \
    --query 'OpenIDConnectProviderList[].Arn' \
    --output text |
    tr '\t' '\n'
)

if (( match_count == 0 )); then
  printf 'PASS: no IAM OIDC provider matches %s\n' "${cluster_issuer}"
else
  printf 'FAIL: found %d matching IAM OIDC provider(s)\n' "${match_count}" >&2
  exit 1
fi
```

Do not delete a matching provider from an existing cluster until every IRSA
workload has been migrated and tested.

## Audit for remaining IRSA dependencies

List every service account with an IRSA role annotation:

```bash
kubectl get serviceaccounts --all-namespaces -o json |
  jq -r '
    .items[] |
    select(.metadata.annotations["eks.amazonaws.com/role-arn"] != null) |
    [
      .metadata.namespace,
      .metadata.name,
      .metadata.annotations["eks.amazonaws.com/role-arn"]
    ] |
    @tsv
  '
```

Review EBS/EFS CSI, AWS Load Balancer Controller, ExternalDNS, autoscalers, and
any custom controllers. Create an equivalent entry in
`workload-identities/terraform.tfvars`, remove the IRSA annotation from the
owning Helm/profile values, and recreate the pods.

## Validate an application identity

After Stage 3, restart the application so the Pod Identity webhook can inject
its configuration:

```bash
kubectl rollout restart deployment/<deployment> -n <namespace>
kubectl rollout status deployment/<deployment> -n <namespace> --timeout=5m
```

Check injection:

```bash
kubectl get pod -n <namespace> -l app=<label> -o json |
  jq -r '.items[0].spec.containers[0].env[]?.name' |
  grep AWS_CONTAINER
```

If the container includes the AWS CLI, verify the assumed identity:

```bash
kubectl exec -n <namespace> deployment/<deployment> -- \
  aws sts get-caller-identity
```

## If Palette did not create the workload agent

First find a compatible add-on version:

```bash
kubernetes_version="$({
  aws eks describe-cluster \
    --name "${WORKLOAD_CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --query 'cluster.version' \
    --output text
})"

aws eks describe-addon-versions \
  --addon-name eks-pod-identity-agent \
  --kubernetes-version "${kubernetes_version}" \
  --region "${AWS_REGION}" \
  --query 'addons[0].addonVersions[].addonVersion' \
  --output text
```

Then either let `workload-identities` own the add-on or install it once with:

```bash
aws eks create-addon \
  --cluster-name "${WORKLOAD_CLUSTER_NAME}" \
  --addon-name eks-pod-identity-agent \
  --addon-version '<compatible-v1.x.x-eksbuild.N>' \
  --region "${AWS_REGION}"
```

Do not install the separate Palette Helm pack when the AWS managed add-on is
already present.
