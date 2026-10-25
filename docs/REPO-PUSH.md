# Publishing this repository to GitHub (from your PC)

Run these on your own computer, not in CloudShell. Suggested repository name: `aws-enterprise-bank-lab` under `github.com/asvinluan`.

## 1. Unzip and check before the first commit

```bash
unzip aws-enterprise-bank-lab.zip
cd aws-enterprise-bank-lab

# Nothing below should print anything
git init -b main
git add -A
git grep --cached -nE '(^|[^0-9])[0-9]{12}([^0-9]|$)' | grep -vE 'ACCOUNT|123456789012|\.github/workflows'
git grep --cached -nE 'AKIA[0-9A-Z]{16}|aws_secret_access_key|BEGIN .*PRIVATE KEY|ghp_|xox[bp]-' -- . ':!docs' ':!.github'
git status --short | grep -E 'tfstate|tfvars$|\.env|\.pem'
```

If any command prints a line, fix it before committing. A 12-digit number is usually an AWS account ID; keep those, ARNs with real IDs, tokens, secrets, your real mobile number and screenshots with the account ID visible out of a public repo.

## 2. Create the repository and push

With the GitHub CLI:

```bash
git commit -m "Initial commit: AWS enterprise bank lab"
gh repo create asvinluan/aws-enterprise-bank-lab --public --source=. --remote=origin --push
```

Or in the browser: create an empty repository (no README, no licence), then:

```bash
git commit -m "Initial commit: AWS enterprise bank lab"
git remote add origin https://github.com/asvinluan/aws-enterprise-bank-lab.git
git push -u origin main
```

## 3. After the first push

1. Open the **Actions** tab and check the `ci` workflow. The first run is the first real `terraform validate`; if it fails, fix what it reports and push again.
2. On your PC, run `terraform init` in `terraform/` once and commit the generated `.terraform.lock.hcl` so provider versions are pinned.
3. Settings, Branches: protect `main` (require a pull request and the `ci` checks).
4. Settings, Code security: turn on secret scanning and push protection.
5. Add repository topics: `aws`, `terraform`, `cloudformation`, `amazon-connect`, `eks`, `serverless`.
6. Pin the repository on your GitHub profile.

## 4. If you later add deployment from GitHub

Use OIDC, never access keys. Scope the role's trust policy `sub` to this repository and branch, for example `repo:asvinluan/aws-enterprise-bank-lab:ref:refs/heads/main`. Never `repo:asvinluan/*:*`.

## 5. Keep it clean

Do not commit `terraform.tfvars`, state files, `backend.tf`, real phone numbers or the account ID. The `.gitignore` covers the first three; the rest is a habit.
