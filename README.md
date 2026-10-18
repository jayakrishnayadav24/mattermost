# Mattermost → EC2, deployed by GitHub Actions (Terraform + Ansible over SSM)

This repo provisions an EC2 host with **Terraform** and deploys **Mattermost** (MySQL +
Mattermost app + Nginx, all Docker containers) with **Ansible**. The pipeline connects to the
instance through **AWS Session Manager (SSM)** — no SSH key is stored anywhere — and authenticates
to AWS using **GitHub OIDC** (no long-lived access keys).

```
git push → GitHub Actions
            ├─ OIDC → assume AWS role (short-lived creds)
            ├─ terraform apply        (VPC, SG[22,80], SSM role, Ubuntu 24.04 EC2)
            ├─ wait for SSM online
            └─ ansible-playbook (over SSM): install Docker, run containers
                      ↓
        http://<public-ip>  →  Nginx :80 → Mattermost :8065 → MySQL :3306
```

## Layout

```
.
├── .github/workflows/deploy.yml   # OIDC → terraform → ansible (SSM)
├── terraform/                     # idempotent infra (S3 remote state)
│   ├── main.tf  variables.tf  outputs.tf  backend.tf
│   └── terraform.tfvars.example
├── ansible/
│   ├── playbook.yml  inventory.yml  ansible.cfg  requirements.yml
│   └── files/nginx/mattermost.conf
├── .gitignore
└── mattermost.md                  # the manual Docker-on-Ubuntu guide
```

---

## One-time AWS setup

You create these **once**, by hand (or a separate bootstrap), because the pipeline needs them to
exist before it can run.

### 1. S3 buckets

```bash
# Terraform remote state (keeps runs idempotent)
aws s3 mb s3://my-mattermost-tfstate --region ap-south-1

# File-transfer bucket used by the aws_ssm Ansible connection plugin
aws s3 mb s3://my-mattermost-ssm-transfer --region ap-south-1
```

### 2. GitHub OIDC provider + IAM role

Create the OIDC identity provider (once per account):

- Provider URL: `https://token.actions.githubusercontent.com`
- Audience: `sts.amazonaws.com`

Create an IAM role the workflow assumes. Its **trust policy** must restrict to your repo:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
      "StringLike":   { "token.actions.githubusercontent.com:sub": "repo:jayakrishnayadav24*/mattermost*" }
    }
  }]
}
```

> **Immutable subject claims (repos created after 2026-07-15):** GitHub now issues the `sub`
> claim with immutable owner/repo IDs embedded, e.g.
> `repo:jayakrishnayadav24@123456/mattermost@456789:ref:refs/heads/main`. A trust policy pinned to
> the old `repo:owner/repo:ref:refs/heads/main` format will NOT match and you get
> *"Not authorized to perform sts:AssumeRoleWithWebIdentity"*. The wildcard pattern
> `repo:jayakrishnayadav24*/mattermost*` above matches both the old and new formats. To pin it
> exactly, decode the real `sub` from the token first (see the troubleshooting note in the repo).

The role also needs a **permissions policy** — the pipeline creates the EC2 and all its
supporting infrastructure, so without this `terraform apply` fails with `AccessDenied`. Attach
this policy to the role (broad for first-run simplicity; tighten `Resource` and conditions for
production):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TerraformInfra",
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances", "ec2:TerminateInstances", "ec2:StartInstances", "ec2:StopInstances",
        "ec2:Describe*", "ec2:GetConsoleOutput",
        "ec2:CreateTags", "ec2:DeleteTags",
        "ec2:CreateVpc", "ec2:DeleteVpc", "ec2:ModifyVpcAttribute",
        "ec2:CreateSubnet", "ec2:DeleteSubnet", "ec2:ModifySubnetAttribute",
        "ec2:CreateInternetGateway", "ec2:DeleteInternetGateway",
        "ec2:AttachInternetGateway", "ec2:DetachInternetGateway",
        "ec2:CreateRouteTable", "ec2:DeleteRouteTable",
        "ec2:CreateRoute", "ec2:DeleteRoute",
        "ec2:AssociateRouteTable", "ec2:DisassociateRouteTable",
        "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress",
        "ec2:ModifyInstanceAttribute",
        "ec2:AssociateIamInstanceProfile", "ec2:DisassociateIamInstanceProfile",
        "iam:CreateRole", "iam:DeleteRole", "iam:GetRole",
        "iam:TagRole", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
        "iam:AttachRolePolicy", "iam:DetachRolePolicy",
        "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy",
        "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile",
        "iam:GetInstanceProfile", "iam:ListInstanceProfiles",
        "iam:ListInstanceProfilesForRole",
        "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PassSsmRoleToEc2Only",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::<ACCOUNT_ID>:role/mattermost-ec2-ssm-role",
      "Condition": {
        "StringEquals": { "iam:PassedToService": "ec2.amazonaws.com" }
      }
    },
    {
      "Sid": "TerraformState",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": [
        "arn:aws:s3:::<TF_STATE_BUCKET>",
        "arn:aws:s3:::<TF_STATE_BUCKET>/*",
        "arn:aws:s3:::<SSM_BUCKET>",
        "arn:aws:s3:::<SSM_BUCKET>/*"
      ]
    },
    {
      "Sid": "AnsibleOverSSM",
      "Effect": "Allow",
      "Action": [
        "ssm:SendCommand",
        "ssm:StartSession",
        "ssm:TerminateSession",
        "ssm:ResumeSession",
        "ssm:DescribeInstanceInformation",
        "ssm:DescribeSessions",
        "ssm:GetCommandInvocation",
        "ssm:ListCommandInvocations"
      ],
      "Resource": "*"
    }
  ]
}
```

Notes:
- **Attach this as ONE inline policy under a single name** (e.g. `mattermost-gha`). Do not split
  it across multiple `aws iam put-role-policy` calls with different documents — `put-role-policy`
  *replaces* the whole policy for a given name, so a second call with the same name silently drops
  the earlier statements (this is what causes the `iam:PassRole`/`RunInstances` failures to
  reappear). One name, one complete document.
- The EC2 actions can be the explicit create/describe/delete set, or simply `ec2:*` for this
  project (Terraform touches many EC2 resource types; the explicit list is easy to under-scope).
- `iam:PassRole` is scoped to the single `mattermost-ec2-ssm-role` (the EC2 instance role
  Terraform creates) and restricted to EC2 via the `iam:PassedToService` condition — never use
  `PassRole` on `"*"`. This is a *different* role from the GitHub Actions OIDC role — do not reuse
  one name for both, or `terraform apply` fails with `EntityAlreadyExists`.
- Replace `<ACCOUNT_ID>`, `<TF_STATE_BUCKET>`, and `<SSM_BUCKET>` with your real values.

### 3. GitHub repo configuration

Under **Settings → Secrets and variables → Actions**:

**Variables** (not secret):

| Name | Example |
|------|---------|
| `AWS_ROLE_ARN` | `arn:aws:iam::<ACCOUNT_ID>:role/mattermost-gha-oidc` |
| `AWS_REGION` | `ap-south-1` |
| `TF_STATE_BUCKET` | `my-mattermost-tfstate` |
| `SSM_BUCKET` | `my-mattermost-ssm-transfer` |

**Secrets**:

| Name | Purpose |
|------|---------|
| `MM_ROOT_PW` | MySQL root password |
| `MM_DB_PW` | MySQL app-user (`mmuser`) password |

> Also set the real state-bucket name in `terraform/backend.tf` (or rely on the
> `-backend-config` flags the workflow passes at init — both are wired up).

---

## Run it

```bash
git add .
git commit -m "Deploy Mattermost via SSM"
git push origin main
```

Or trigger manually: **Actions → Deploy Mattermost to EC2 (SSM) → Run workflow**.

When it finishes, the run **Summary** shows the instance ID and the URL. Open
`http://<public-ip>` and create the first admin account.

## Troubleshooting OIDC (all of these were hit and fixed)

The `Configure AWS credentials (OIDC)` step is where first-time setups fail. The error text
tells you which prerequisite is missing:

| Error | Cause | Fix |
|-------|-------|-----|
| `Could not assume role with OIDC: The web identity token provided could not be validated` | The **OIDC identity provider** for `token.actions.githubusercontent.com` does not exist in the account | Create it (Provider URL `https://token.actions.githubusercontent.com`, Audience `sts.amazonaws.com`) |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | The role **trust policy** does not match the token's `sub` claim | Fix the `sub` pattern (see below) |
| `Permission to <repo> denied to <other-user>` (on `git push`) | Git authenticated as the wrong GitHub account | `gh auth login` as the repo owner, then `gh auth setup-git` |

**The `sub` claim gotcha (immutable subject IDs):** repos created after **2026-07-15** get a
`sub` with embedded owner/repo IDs:

```
repo:jayakrishnayadav24@<ownerID>/mattermost@<repoID>:ref:refs/heads/main
```

A trust policy pinned to the old `repo:owner/repo:ref:refs/heads/main` form will NOT match and
you get *"Not authorized"*. Use a wildcard that matches both old and new forms:

```json
"StringLike": { "token.actions.githubusercontent.com:sub": "repo:jayakrishnayadav24*/mattermost*" }
```

Update the live role without redeploying:

```bash
aws iam update-assume-role-policy --role-name <gha-role> --policy-document file://trust.json
```

> **Note on IDs/names used here:** this deployment reuses the role `mattermost-ssm-role` as the
> GitHub Actions OIDC role (account `<ACCOUNT_ID>`, region `ap-south-1`). The role name does not
> matter — what matters is that its **trust policy** points at the GitHub OIDC provider and its
> `sub` pattern matches your repo. `AWS_ROLE_ARN` in GitHub Variables must be *this* role.

## Idempotency

- **Terraform** uses S3 remote state with native lockfile locking, so repeated runs reconcile
  the same resources instead of creating duplicates.
- **Ansible** uses `community.docker` modules and apt package state, so re-running converges the
  host rather than stacking changes. Pushing again = safe redeploy.

## Why SSM instead of SSH

- No SSH key to generate, store, or rotate in GitHub.
- The deploy path needs **no inbound port** — SSM works outbound-only via the instance's IAM role.
- Ports 22 and 80 are still opened in the security group (per request): 22 for manual break-glass
  SSH if you ever add a key, 80 to serve Mattermost.

## Local run (optional)

```bash
cd terraform
terraform init -backend-config="bucket=my-mattermost-tfstate"
terraform apply -var "ssm_transfer_bucket=my-mattermost-ssm-transfer"

cd ../ansible
ansible-galaxy collection install -r requirements.yml
export TARGET_INSTANCE_ID=$(cd ../terraform && terraform output -raw instance_id)
export SSM_BUCKET=my-mattermost-ssm-transfer
export AWS_REGION=ap-south-1
ansible-playbook playbook.yml \
  -e "mysql_root_password=... mysql_password=... site_url=http://$(cd ../terraform && terraform output -raw public_ip)"
```

## Teardown

**From GitHub Actions (recommended):** the workflow has an `action` input. Go to
**Actions → Deploy Mattermost to EC2 (SSM) → Run workflow**, set **action = `destroy`**, and run.
That runs `terraform destroy` over the same OIDC role and S3 state. A plain push (or
`action = apply`) deploys as usual.

**Locally:**

```bash
cd terraform
terraform destroy -var "ssm_transfer_bucket=my-mattermost-ssm-transfer"
```

> `destroy` removes the EC2 host and its data. Empty the S3 buckets separately if you no longer
> need the state/transfer buckets.
