{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EKSPodIdentityManagement",
      "Effect": "Allow",
      "Action": [
        "eks:ListPodIdentityAssociations",
        "eks:CreatePodIdentityAssociation",
        "eks:DeletePodIdentityAssociation"
      ],
      "Resource": "*"
    },
    {
      "Sid": "DescribeManagementNodes",
      "Effect": "Allow",
      "Action": "ec2:DescribeInstances",
      "Resource": "*"
    },
    {
      "Sid": "GetPaletteRole",
      "Effect": "Allow",
      "Action": "iam:GetRole",
      "Resource": "__PALETTE_ROLE_ARN__"
    },
    {
      "Sid": "PassPaletteRoleForPodIdentity",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "__PALETTE_ROLE_ARN__"
    }
  ]
}

