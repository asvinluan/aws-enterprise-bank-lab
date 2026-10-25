# Runbook (Windows PowerShell edition): get it running, then get it deleted

For a tired engineer on a Windows PC. Copy and paste into **PowerShell**. Each step says what you should see.

This is the PowerShell version of `RUNBOOK.md`. That one is for AWS CloudShell (Linux/bash). Use this one if you are typing at a `PS C:\...>` prompt.

**What this builds:** the Meridian Bank platform in Sydney (`ap-southeast-2`): network, Lambdas, API, data stores, and optionally the expensive parts (NAT, endpoints, EKS, Kinesis, WAF).
**What it does not build:** the Amazon Connect instance, flows, queues, Lex bot, Contact Lens and Q. Those are console work (Part 7).

> **PowerShell rules used below.** A backtick `` ` `` at the end of a line continues the command on the next line. Variables start with `$`. `&&` and `grep` do not exist in Windows PowerShell; this guide never uses them. Anything in single quotes is literal text.

---

## Part 0. Five checks before anything (3 minutes)

| # | Check | How |
|---|---|---|
| 1 | You are in a **sandbox** account, not a work account | Look at the account alias in the console |
| 2 | The Region is **Asia Pacific (Sydney)** | Top-right of the console |
| 3 | A **budget alarm** exists | Billing, Budgets, create a 10 USD monthly budget (steps in `CLEANUP.md`) |
| 4 | Nothing from an earlier run is still billing | Part 6 `scan` should be empty |
| 5 | You have decided **today's end time** | The expensive profile costs about 25 to 30 USD a day. Plan to destroy it the same day |

---

## Part 1. One-time setup on your PC (10 minutes)

Open PowerShell. Install the tools (each line is one tool; skip any you already have):

```powershell
winget install -e --id Git.Git
winget install -e --id Amazon.AWSCLI
winget install -e --id Hashicorp.Terraform
winget install -e --id Kubernetes.kubectl
winget install -e --id Docker.DockerDesktop
```

**Close PowerShell and open a new window** (the new tools are not visible until you do). Check:

```powershell
git --version
aws --version
terraform version
kubectl version --client
docker --version
```

**You should see** a version number for each. Docker Desktop must also be **running** (whale icon in the system tray) before any `docker` command.

You only need `kubectl` and Docker for the expensive EKS profile. The cheap profile needs only Git, the AWS CLI and Terraform (or just the AWS CLI for CloudFormation).

### Sign in to AWS

Preferred (IAM Identity Center / SSO):

```powershell
aws configure sso
aws sso login --profile YOUR-PROFILE-NAME
$env:AWS_PROFILE = "YOUR-PROFILE-NAME"
```

Or, for a **sandbox** IAM user with access keys (never use keys from a work account, and never commit them):

```powershell
aws configure
```

Then, in **every new PowerShell window**:

```powershell
$env:AWS_REGION = "ap-southeast-2"
aws sts get-caller-identity
```

**You should see** your account number and ARN. If not, the sign-in did not work. Fix this before going on.

### Allow the scripts to run (this window only)

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
cd C:\Users\AV\Downloads\GitHub\aws-enterprise-bank-lab
Get-ChildItem -Recurse | Unblock-File
```

`Unblock-File` removes the "downloaded from the internet" mark that Windows puts on files from a zip. The policy change lasts only until you close the window.

---

## Pick one track

| Track | Use it when | Time |
|---|---|---|
| **A. GitHub** | You want the repo online with a green tick (do this once) | 10 min |
| **B. Terraform** | You want the estate built from code (recommended) | cheap profile 10 min, full profile 40 min |
| **C. CloudFormation** | You want AWS-native stacks, or you are not allowed Terraform | cheap profile 15 min, full profile 45 min |

Use **B or C, not both**, in the same account at the same time: they would try to create the same names.

---

## Part 2. Track A: GitHub

You are already in the repo folder if you unzipped it. If not:

```powershell
cd C:\Users\AV\Downloads\GitHub\aws-enterprise-bank-lab
dir
```

**You should see** `.github`, `app`, `cleanup`, `cloudformation`, `docs`, `terraform`, `tools`, `.gitignore`, `README.md`. (Add `-Force` to `dir` to see hidden items.)

```powershell
git config --global user.name "Anthony Vinluan"
git config --global user.email "YOUR-GITHUB-EMAIL"
git init -b main
git add -A
```

Safety checks. **Blank output means clean.** If anything prints, stop and read it:

```powershell
git grep --cached -nE '(^|[^0-9])[0-9]{12}([^0-9]|$)' -- . ':!docs' ':!.github' | Select-String -NotMatch 'ACCOUNT|123456789012|0{12}'
git grep --cached -nE 'AKIA[0-9A-Z]{16}|aws_secret_access_key|BEGIN .*PRIVATE KEY|ghp_|xox[bp]-' -- . ':!docs' ':!.github'
git status --short | Select-String 'tfstate|tfvars$|\.env|\.pem'
```

Commit:

```powershell
git commit -m "Initial commit: AWS enterprise bank lab"
```

Push. **Option 1, browser:** go to https://github.com/new, sign in as `asvinluan`, name it `aws-enterprise-bank-lab`, choose Public, leave README, .gitignore and licence **unticked**, click Create. Then:

```powershell
git remote add origin https://github.com/asvinluan/aws-enterprise-bank-lab.git
git push -u origin main
```

A browser window opens to sign in to GitHub. Approve it.

**Option 2, GitHub CLI** (`winget install -e --id GitHub.cli`, then reopen PowerShell):

```powershell
gh auth login
gh repo create asvinluan/aws-enterprise-bank-lab --public --source=. --remote=origin --push
```

**You should see:** a line ending `main -> main`, your files on GitHub, and under the **Actions** tab a `ci` run starting.

**If CI is red** on the first run, that is normal: it is the first real `terraform validate` of this code. Open the failed step, read the one-line error, fix the file, commit and push again. Do not skip it.

**After it goes green:** run `terraform init` once inside `terraform\` and commit `terraform\.terraform.lock.hcl`:

```powershell
cd terraform
terraform init
cd ..
git add terraform/.terraform.lock.hcl
git commit -m "Pin provider versions"
git push
```

Never put AWS access keys in GitHub. If you later deploy from GitHub, use OIDC (see `REPO-PUSH.md`).

---

## Part 3. Track B: Terraform

### Step 1. The cheap profile (cents a day)

```powershell
cd C:\Users\AV\Downloads\GitHub\aws-enterprise-bank-lab\terraform
terraform init
terraform plan  -var-file=envs/minimal.tfvars       # read it before you apply
terraform apply -var-file=envs/minimal.tfvars       # type yes
terraform output cost_switches
terraform output private_subnet_zone_ids
```

**You should see:** `Apply complete!`; `cost_switches` showing every paid switch as `false`; and three **different** `apse2-azN` values.

### Step 2. Your own phone number (optional, never commit it)

Create a file called `terraform.tfvars` (git ignores it) with your number in the `seed_customers` map, copying the shape from `variables.tf`:

```powershell
notepad terraform.tfvars
```

Then run the `apply` line from Step 1 again.

### Step 3. Test the chat endpoint (needs Connect wired, see Part 7)

```powershell
$url = terraform output -raw chat_url
Invoke-RestMethod -Method Post -Uri $url -ContentType 'application/json' -Body '{"name":"Test"}'
```

### Step 4. The expensive profile (only if you need to demo it)

Everything on costs about 25 to 30 USD a day. Do it in one sitting.

1. Find your public IP and put it in `envs/full.tfvars`:

```powershell
(Invoke-RestMethod https://checkip.amazonaws.com).Trim()
notepad envs\full.tfvars
```

Uncomment and set `eks_public_access_cidrs = ["YOUR.IP.ADDRESS/32"]`. Save.

2. Apply (15 to 20 minutes; the cluster is the slow part):

```powershell
terraform apply -var-file=envs/full.tfvars
terraform output cost_switches        # now shows what is billing
```

3. Build and push the container image (Docker Desktop must be running):

```powershell
$repo = terraform output -raw ecr_repository_url
aws ecr get-login-password --region ap-southeast-2 | docker login --username AWS --password-stdin $repo.Split('/')[0]
docker build -t "${repo}:v1" ..\app\account-service
docker push "${repo}:v1"
```

4. Point `kubectl` at the cluster and deploy:

```powershell
aws eks update-kubeconfig --region ap-southeast-2 --name (terraform output -raw eks_cluster_name)
$sg   = terraform output -raw sg_account_service_id
$acct = aws sts get-caller-identity --query Account --output text
(Get-Content ..\app\k8s\deployment.yaml -Raw).Replace('SG_ACCOUNT_SERVICE_ID', $sg).Replace('ACCOUNT_ID', $acct) | kubectl apply -f -
kubectl get pods -o wide              # 3 pods Running, spread over nodes
kubectl get svc account-service       # EXTERNAL-IP is a private (internal) DNS name
```

5. Hand the service address to the Lambda. Take the DNS name from the last command:

```powershell
terraform apply -var-file=envs/full.tfvars -var "account_api_url=http://INTERNAL-DNS-NAME:8080"
```

**You should see:** three `Running` pods and an address that starts with `internal-`. If it does not start with `internal-`, stop and run `kubectl delete svc account-service`: it is exposed to the internet.

### Step 5. Destroy (same day)

```powershell
(Get-Content ..\app\k8s\deployment.yaml -Raw).Replace('SG_ACCOUNT_SERVICE_ID', $sg).Replace('ACCOUNT_ID', $acct) | kubectl delete -f -
terraform destroy -var-file=envs/full.tfvars        # use the same file you applied with
```

(If you opened a new window since Step 4, set `$sg` and `$acct` again with the two lines from Step 4 item 4, or just run `kubectl delete svc account-service` instead of the first line.)

Buckets are created with `force_destroy_buckets = true` (the default), so `destroy` empties them. The one exception is the optional Object Lock evidence bucket: it keeps objects for one day (Governance mode). If `destroy` stops there, use the CloudShell clean-up script (Part 6) with `delete s3 --yes`.

---

## Part 4. Track C: CloudFormation

Four independent stacks linked by exports. Order matters once on the way up. The PowerShell scripts do the same job as the bash ones.

```powershell
cd C:\Users\AV\Downloads\GitHub\aws-enterprise-bank-lab\cloudformation
```

### Step 1. The cheap profile (cents a day)

```powershell
.\deploy.ps1 data
.\deploy.ps1 network
.\deploy.ps1 compute
.\deploy.ps1 containers
.\seed-dynamodb.ps1
```

Each command prints a table of outputs. **You should see** `CREATE_COMPLETE` or `UPDATE_COMPLETE` per stack. `containers` creates only the ECR repository while EKS is off. `seed-dynamodb.ps1` loads the demo customers and holidays (CloudFormation cannot): open it in Notepad first and replace the first phone number with your own mobile in `+61...` form, on your copy only, never in a commit.

`compute` also attaches the S3 trigger to the recordings bucket, filtered to the `connect/` prefix. That is required: without it the router would fire on its own output forever.

### Step 2. The expensive profile (only if you need it)

```powershell
$myip = (Invoke-RestMethod https://checkip.amazonaws.com).Trim()

.\deploy.ps1 data       EnableKinesis=true EnableFirehose=true EnableEvidenceBucket=true
.\deploy.ps1 network    EnableNat=true EnableInterfaceEndpoints=true
.\deploy.ps1 compute    EnableWaf=true EnableAlarms=true AlarmEmail=you@example.com
.\deploy.ps1 containers EnableEks=true ApiAccessCidr=$myip/32          # 15 to 20 minutes
```

**Important:** `containers` defaults `ApiAccessCidr` to `0.0.0.0/0`. Always set it to your own `/32`.

Build and push the image, then deploy to the cluster as in Part 3, Step 4, items 3 and 4, with these differences: the repository URI is the stack output `RepositoryUri`, the cluster name is `meridian-lab`, and the security group is the `SgAccountServiceId` output of the network stack:

```powershell
aws cloudformation describe-stacks --stack-name mb-containers --query "Stacks[0].Outputs" --output table
aws cloudformation describe-stacks --stack-name mb-network    --query "Stacks[0].Outputs" --output table
$repo = aws cloudformation describe-stacks --stack-name mb-containers --query "Stacks[0].Outputs[?OutputKey=='RepositoryUri'].OutputValue" --output text
$sg   = aws cloudformation describe-stacks --stack-name mb-network    --query "Stacks[0].Outputs[?OutputKey=='SgAccountServiceId'].OutputValue" --output text
```

Finally give the Lambda the service address and redeploy compute. **Repeat every non-default parameter** on each `deploy.ps1 compute` call, or it reverts to the cheap default:

```powershell
.\deploy.ps1 compute AccountApiUrl=http://INTERNAL-DNS-NAME:8080 EnableWaf=true EnableAlarms=true AlarmEmail=you@example.com
```

### Step 3. Destroy (same day)

```powershell
kubectl delete svc account-service        # if you deployed it: removes the load balancer first
.\destroy.ps1                              # DRY RUN: read what it lists
.\destroy.ps1 -Yes                         # containers, compute, data, network, in that order
```

`destroy.ps1` empties the buckets first, because CloudFormation cannot delete a bucket that has objects.

---

## Part 5. Reading the results

| Command | What it tells you |
|---|---|
| `terraform output cost_switches` | Which paid services are on |
| `aws cloudformation describe-stacks --query "Stacks[].[StackName,StackStatus]" --output table` | Stack states |
| `aws sts get-caller-identity` | Which account you are about to change |
| `kubectl get pods -o wide` | Whether the account service is running |

---

## Part 6. The safety net: stop-the-meter (this one runs in CloudShell)

`stop-the-meter.sh` is a bash script, and Windows PowerShell cannot run bash scripts. That is fine: it is designed for **AWS CloudShell**, which is Linux and is already signed in to your account.

1. In the AWS Console click the `>_` icon (CloudShell) in the top bar. Check the Region is Sydney.
2. Actions menu, Upload file, choose `cleanup\stop-the-meter.sh` from your PC.
3. In CloudShell:

```bash
chmod +x stop-the-meter.sh
./stop-the-meter.sh scan                  # what exists
./stop-the-meter.sh costs                 # what you were charged, last 7 days
./stop-the-meter.sh delete all            # DRY RUN
./stop-the-meter.sh delete all --yes      # real
./stop-the-meter.sh scan                  # must be empty
```

It leaves Connect phone numbers, the Connect instance and KMS keys alone unless you add `--include-numbers`, `--include-instance` or `--include-kms`.

---

## Part 7. What the code does not do: the Connect console work

Do these in order. Full detail is in `PLAYBOOK.md` (modules 2, 5, 6, 7, 8).

1. **Create the instance** (alias `meridian-cc`, store users in Connect). Claim a number if you need a phone. Note the **instance ID** (the UUID in the instance ARN).
2. **Build** hours of operation, queues (set a maximum contacts value on each), routing profiles, quick connects.
3. **Build the flows**: `MB-IdentifyCaller` module, `MB-Main`, `MB-CustomerQueue`, `MB-BreakGlass`. Save, then **Publish** each. Note the `MB-Main` flow ID.
4. **Build the Lex bot** `MB-Bot`, version it, create alias `Prod`, add it to the instance.
5. **Wire the code to the instance.** Terraform: add these to `terraform.tfvars` and apply again:

```hcl
connect_instance_id      = "<instance uuid>"
connect_contact_flow_id  = "<MB-Main flow id>"
wire_connect             = true
```

CloudFormation: `.\deploy.ps1 compute ConnectInstanceId=<uuid> ConnectContactFlowId=<flow id> WireConnect=true`

6. **Call it.** Use the PLAYBOOK module 18 test table, especially T3 (scale the account service to zero) and T8 (remove the Lambda's DynamoDB permission).

---

## When it goes wrong (PowerShell and Windows)

| What you see | Most likely cause | Fix |
|---|---|---|
| `... is not recognized as the name of a cmdlet` for `aws`, `terraform`, `git`, `kubectl` | The tool is not installed, or this window predates the install | Install with `winget` (Part 1), close PowerShell, open a new window |
| `running scripts is disabled on this system` | Windows execution policy | `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` |
| `... is not digitally signed` or a security warning when running `.ps1` | Files from a zip carry a "downloaded" mark | `Get-ChildItem -Recurse \| Unblock-File` in the repo folder |
| `grep : The term 'grep' is not recognized` | You pasted a bash command | Use the PowerShell lines in this guide (`Select-String` instead of `grep`) |
| `The token '&&' is not a valid statement separator` | Bash syntax in Windows PowerShell 5.1 | Put each command on its own line |
| `Unable to locate credentials` or `ExpiredToken` | Not signed in, or the SSO session expired | `aws sso login --profile ...`, then `aws sts get-caller-identity` |
| Everything runs in the wrong Region | `$env:AWS_REGION` not set in this window | `$env:AWS_REGION = "ap-southeast-2"` |
| `Cannot connect to the Docker daemon` or `error during connect` | Docker Desktop is not running | Start Docker Desktop, wait for the whale icon to settle |
| `enable_eks needs enable_nat` | Guard working as designed | Set `enable_nat = true` |
| `Error acquiring the state lock` | An earlier run was cut off | `terraform force-unlock <ID>` (only if sure nobody else is running) |
| `BucketAlreadyExists` | Bucket names include your account ID, so this means a leftover | Run the clean-up script (Part 6), or delete the old bucket |
| Pods `Pending` | Not enough node capacity | `kubectl describe pod`, raise `eks_node_desired` |
| Service address is not `internal-...` | Annotation missing | `kubectl delete svc account-service` immediately, fix, redeploy |
| CloudFormation `DELETE_FAILED` | A bucket has objects, or a network interface still exists | Run `.\destroy.ps1 -Yes` again after a few minutes |
| Subnet will not delete | Leftover Lambda network interface (can last minutes) | Wait 10 to 20 minutes and retry |
| `Export ... cannot be deleted as it is in use` | Wrong delete order | Delete `containers`, then `compute`, then `data` and `network` |
| Call drops with no message | A flow branch is not connected | `PLAYBOOK.md` module 6 checklist; check flow logs by `ContactId` |
| Bill is climbing | Something is still on | CloudShell: `./stop-the-meter.sh scan`, then `delete all --yes` |

---

## Done checklist

- [ ] Budget alarm exists
- [ ] Cheap profile applied and `cost_switches` all `false` (or you know why not)
- [ ] If you turned on the full profile: the destroy command is written in your calendar for today
- [ ] `stop-the-meter.sh scan` is empty at the end of the day
- [ ] Repo is on GitHub, CI is green, no account IDs, keys or real phone numbers committed
