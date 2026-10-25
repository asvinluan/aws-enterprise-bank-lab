# Publishing this repository to GitHub (Windows PowerShell)

Run these in **PowerShell on your PC**. Suggested repository name: `aws-enterprise-bank-lab` under `github.com/asvinluan`.

## 1. Go to the folder

```powershell
cd C:\Users\AV\Downloads\GitHub\aws-enterprise-bank-lab
dir
```

You should see `.github`, `app`, `cleanup`, `cloudformation`, `docs`, `terraform`, `tools`, `.gitignore`, `README.md`. If the zip is not unzipped yet: `Expand-Archive .\aws-enterprise-bank-lab.zip -DestinationPath .` then `cd aws-enterprise-bank-lab`.

## 2. Install and check git

```powershell
git --version
```

If it is not recognised: `winget install -e --id Git.Git`, close PowerShell, open a new window.

## 3. Tell git who you are (once)

```powershell
git config --global user.name "Anthony Vinluan"
git config --global user.email "YOUR-GITHUB-EMAIL"
```

## 4. Start the repository and check it is clean

```powershell
git init -b main
git add -A
```

**Blank output means clean.** If a command prints a line, stop and read it. A 12-digit number is usually an AWS account ID. Keep account IDs, ARNs with real IDs, tokens, secrets, your real mobile number and screenshots showing the account ID out of a public repo.

```powershell
git grep --cached -nE '(^|[^0-9])[0-9]{12}([^0-9]|$)' -- . ':!docs' ':!.github' | Select-String -NotMatch 'ACCOUNT|123456789012|0{12}'
git grep --cached -nE 'AKIA[0-9A-Z]{16}|aws_secret_access_key|BEGIN .*PRIVATE KEY|ghp_|xox[bp]-' -- . ':!docs' ':!.github'
git status --short | Select-String 'tfstate|tfvars$|\.env|\.pem'
```

## 5. Commit

```powershell
git commit -m "Initial commit: AWS enterprise bank lab"
```

## 6. Create the GitHub repository and push

**Option 1: browser (easiest).**

1. Go to https://github.com/new and sign in as `asvinluan`.
2. Repository name `aws-enterprise-bank-lab`, choose Public.
3. Leave "Add a README", ".gitignore" and "licence" **unticked**. Click Create repository.
4. In PowerShell:

```powershell
git remote add origin https://github.com/asvinluan/aws-enterprise-bank-lab.git
git push -u origin main
```

A browser window opens to sign in to GitHub. Approve it.

**Option 2: GitHub CLI.**

```powershell
winget install -e --id GitHub.cli
```

Close and reopen PowerShell, then:

```powershell
gh auth login
gh repo create asvinluan/aws-enterprise-bank-lab --public --source=. --remote=origin --push
```

**You should see** a line ending `main -> main`, then your files on the GitHub page.

## 7. After the first push

1. Open the **Actions** tab and check the `ci` workflow. The first run is the first real `terraform validate`. If it fails, read the one-line error in the failed step, fix the file, and push again.
2. Pin the provider versions: run `terraform init` once, then commit the lock file.

```powershell
cd terraform
terraform init
cd ..
git add terraform/.terraform.lock.hcl
git commit -m "Pin provider versions"
git push
```

3. Settings, Branches: protect `main` (require a pull request and the `ci` checks).
4. Settings, Code security: turn on secret scanning and push protection.
5. Add repository topics: `aws`, `terraform`, `cloudformation`, `amazon-connect`, `eks`, `serverless`.
6. Pin the repository on your GitHub profile.

## 8. If a step fails

| Message | Fix |
|---|---|
| `git : The term 'git' is not recognized` | Install Git (step 2) and open a new PowerShell window |
| `grep : The term 'grep' is not recognized` | You pasted a bash command. Use the `Select-String` versions above |
| `fatal: not a git repository` | You are in the wrong folder. `cd` to the repo folder (step 1) |
| `Author identity unknown` | Run the two `git config` lines in step 3 |
| `remote origin already exists` | `git remote set-url origin https://github.com/asvinluan/aws-enterprise-bank-lab.git` |
| `Repository not found` or a 403 | The GitHub repo does not exist yet, or you signed in as a different account. Create it (step 6) and sign in as `asvinluan` |
| `failed to push some refs` / `fetch first` | You ticked "Add a README" when creating the repo. `git pull origin main --allow-unrelated-histories`, then `git push -u origin main` |
| The sign-in window closes before you can approve | `gh auth login`, or create a Personal Access Token under GitHub Settings, Developer settings, and paste it when asked for a password |

## 9. Later: deploying from GitHub

Use OIDC, never access keys. Scope the role's trust policy `sub` to this repository and branch, for example `repo:asvinluan/aws-enterprise-bank-lab:ref:refs/heads/main`. Never `repo:asvinluan/*:*`.

Do not commit `terraform.tfvars`, state files, `backend.tf`, real phone numbers or the account ID. The `.gitignore` covers the first three; the rest is a habit.
