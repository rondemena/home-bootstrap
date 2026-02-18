# SDLC Tool Integrations

**Task**: T067 - Cross-service integration documentation
**Last updated**: 2026-02-17

This document describes how the SDLC tools in this stack are wired
together. Each section covers one integration point: the two services
involved, the credential flow, and the steps to complete the setup on a
live cluster.

---

## Table of Contents

1. [GitLab --> Jenkins (Webhook CI Trigger)](#1-gitlab----jenkins-webhook-ci-trigger)
2. [Jenkins --> Harbor (Container Image Push)](#2-jenkins----harbor-container-image-push)
3. [Woodpecker --> Gitea (OAuth2 Authentication)](#3-woodpecker----gitea-oauth2-authentication)
4. [Sealed Secrets Workflow](#4-sealed-secrets-workflow)

---

## 1. GitLab --> Jenkins (Webhook CI Trigger)

### Overview

When a developer pushes code to a GitLab CE repository, a webhook fires
to Jenkins, which triggers the matching multibranch pipeline or freestyle
project build. This is the primary CI integration in the stack.

### Components

| Component | Location | Purpose |
|-----------|----------|---------|
| GitLab plugin (Jenkins) | `code/k8s/apps/jenkins/values.yaml` JCasC `gitlab-config` | Receives webhooks, polls GitLab API |
| GitLab API token secret | `code/k8s/apps/jenkins/sealed-secrets/gitlab-api-token.yaml` | Authenticates Jenkins to GitLab API |
| Jenkins webhook URL | `https://jenkins.apps.home.lab/project/<job-name>` | Endpoint GitLab calls on push events |

### How It Works

```
Developer --> git push --> GitLab CE
                             |
                             v
                     System Hook / Project Webhook
                             |
                             v
              https://jenkins.apps.home.lab/project/<job-name>
                             |
                             v
                     Jenkins GitLab Plugin
                     (validates token, triggers build)
```

### Jenkins JCasC Configuration (already in place)

The Jenkins Helm values at `code/k8s/apps/jenkins/values.yaml` include
a JCasC config script `gitlab-config` that sets up:

```yaml
unclassified:
  gitLabConnectionConfig:
    connections:
      - name: "GitLab Home Lab"
        url: "https://gitlab.apps.home.lab"
        apiTokenId: "gitlab-api-token"
        clientBuilderId: "autodetect"
        ignoreCertErrors: true
    useAuthenticatedEndpoint: true
```

The `apiTokenId: "gitlab-api-token"` references a Jenkins credential
that is populated from the Kubernetes secret `gitlab-api-token` in the
`jenkins` namespace.

### Setup Steps

#### Step 1: Create a GitLab Personal Access Token

1. Log in to GitLab CE at `https://gitlab.apps.home.lab` as an admin
   or the service account that owns the repositories.
2. Navigate to **User Settings > Access Tokens**.
3. Create a new token with the following scopes:
   - `api` (full API access for webhook validation and commit status)
   - `read_repository` (clone repos during builds)
4. Copy the generated token value. You will need it in Step 2.

#### Step 2: Create and Seal the GitLab API Token Secret

```bash
# Create the plain-text Kubernetes secret (do NOT apply this directly)
kubectl create secret generic gitlab-api-token \
  --from-literal=gitlab-api-token=glpat-XXXXXXXXXXXXXXXXXXXX \
  --namespace=jenkins \
  --dry-run=client -o yaml > /tmp/gitlab-api-token.yaml

# Seal it with kubeseal (requires the Sealed Secrets controller to be running)
kubeseal --format=yaml \
  --controller-name=sealed-secrets \
  --controller-namespace=kube-system \
  < /tmp/gitlab-api-token.yaml \
  > code/k8s/apps/jenkins/sealed-secrets/gitlab-api-token.yaml

# Clean up the plaintext file
rm /tmp/gitlab-api-token.yaml
```

After sealing, commit the resulting SealedSecret to the repository.
The Sealed Secrets controller will decrypt it into a regular Secret in
the `jenkins` namespace.

#### Step 3: Configure the GitLab Webhook

**Option A: Per-project webhook** (recommended for specific repos)

1. In GitLab, navigate to the project > **Settings > Webhooks**.
2. Add a new webhook:
   - **URL**: `https://jenkins.apps.home.lab/project/<jenkins-job-name>`
   - **Secret token**: A shared secret string (configure the same value
     in Jenkins job settings under "GitLab webhook" trigger).
   - **Trigger**: Push events (and optionally Merge request events).
   - **SSL verification**: Disable (self-signed certs in home lab).
3. Click **Add webhook** and use **Test** to verify connectivity.

**Option B: System hook** (triggers for all projects)

1. In GitLab, navigate to **Admin Area > System Hooks**.
2. Add a new system hook:
   - **URL**: `https://jenkins.apps.home.lab/project/<jenkins-job-name>`
   - **Secret token**: Shared secret string.
   - **Trigger**: Push events, Merge request events.
3. Click **Add system hook**.

> **Note**: The Jenkins GitLab plugin automatically validates the webhook
> payload using the API token configured in JCasC. For per-project
> webhooks with a secret token, configure the same token in the Jenkins
> job under **Build Triggers > GitLab webhook > Secret token**.

#### Step 4: Verify the Integration

1. Create a test repository in GitLab with a `Jenkinsfile`.
2. In Jenkins, create a pipeline job pointing to the GitLab repository.
3. Enable the **Build when a change is pushed to GitLab** trigger.
4. Push a commit to the repository.
5. Verify that Jenkins triggers a build within 60 seconds.

---

## 2. Jenkins --> Harbor (Container Image Push)

### Overview

Jenkins pipelines build container images and push them to the Harbor
registry at `harbor.apps.home.lab`. Authentication uses a Harbor robot
account whose credentials are stored as a Sealed Secret.

### Components

| Component | Location | Purpose |
|-----------|----------|---------|
| Harbor credentials (JCasC) | `code/k8s/apps/jenkins/values.yaml` JCasC `credentials-config` | Stores Harbor username/password in Jenkins |
| Harbor credentials secret | `code/k8s/apps/jenkins/sealed-secrets/harbor-credentials.yaml` | K8s secret with robot account credentials |
| Harbor registry URL | `https://harbor.apps.home.lab` | Container registry endpoint |

### Jenkins JCasC Configuration (already in place)

The Jenkins Helm values include a credential entry with id
`harbor-registry`:

```yaml
credentials:
  system:
    domainCredentials:
      - credentials:
          - usernamePassword:
              scope: GLOBAL
              id: "harbor-registry"
              description: "Harbor registry credentials"
              username: "admin"
              password: "${HARBOR_ADMIN_PASSWORD:-changeit}"
```

### Setup Steps

#### Step 1: Create a Harbor Robot Account

**Via the Harbor UI:**

1. Log in to Harbor at `https://harbor.apps.home.lab`.
2. Navigate to **Administration > Robot Accounts**.
3. Create a new robot account:
   - **Name**: `robot$jenkins` (or any descriptive name)
   - **Expiration**: Set appropriately (or no expiration for home lab)
   - **Permissions**: Push/Pull artifacts on the target project(s)
4. Copy the generated robot account name and secret.

**Via the Harbor API:**

```bash
curl -sk -X POST "https://harbor.apps.home.lab/api/v2.0/robots" \
  -u "admin:changeit" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "jenkins",
    "description": "Jenkins CI push account",
    "duration": -1,
    "level": "system",
    "permissions": [{
      "kind": "project",
      "namespace": "*",
      "access": [
        {"resource": "repository", "action": "push"},
        {"resource": "repository", "action": "pull"},
        {"resource": "tag", "action": "create"}
      ]
    }]
  }'
```

Save the returned `name` and `secret` from the API response.

#### Step 2: Create and Seal the Harbor Credentials Secret

```bash
# Create the plain-text Kubernetes secret (do NOT apply directly)
kubectl create secret generic harbor-credentials \
  --from-literal=username='robot$jenkins' \
  --from-literal=password='<robot-account-secret>' \
  --namespace=jenkins \
  --dry-run=client -o yaml > /tmp/harbor-credentials.yaml

# Seal it with kubeseal
kubeseal --format=yaml \
  --controller-name=sealed-secrets \
  --controller-namespace=kube-system \
  < /tmp/harbor-credentials.yaml \
  > code/k8s/apps/jenkins/sealed-secrets/harbor-credentials.yaml

# Clean up
rm /tmp/harbor-credentials.yaml
```

#### Step 3: Use Harbor in a Jenkinsfile

```groovy
pipeline {
    agent { label 'docker' }
    environment {
        HARBOR = credentials('harbor-registry')
        REGISTRY = 'harbor.apps.home.lab'
    }
    stages {
        stage('Build') {
            steps {
                sh 'docker build -t ${REGISTRY}/myproject/myapp:${BUILD_NUMBER} .'
            }
        }
        stage('Push') {
            steps {
                sh 'echo ${HARBOR_PSW} | docker login ${REGISTRY} -u ${HARBOR_USR} --password-stdin'
                sh 'docker push ${REGISTRY}/myproject/myapp:${BUILD_NUMBER}'
            }
        }
    }
}
```

---

## 3. Woodpecker --> Gitea (OAuth2 Authentication)

### Overview

Woodpecker CI authenticates users via Gitea OAuth2 and automatically
discovers repositories for CI pipeline execution. This is the secondary
(learning) SDLC stack integration.

### Components

| Component | Location | Purpose |
|-----------|----------|---------|
| Woodpecker server env | `code/k8s/apps/woodpecker/values.yaml` | Gitea URL and OAuth config |
| Gitea OAuth credentials | `code/k8s/apps/woodpecker/sealed-secrets/gitea-oauth.yaml` | OAuth2 client ID and secret |
| Woodpecker agent secret | `code/k8s/apps/woodpecker/sealed-secrets/woodpecker-secret.yaml` | Server-agent communication token |

### Woodpecker Configuration (already in place)

The Woodpecker Helm values at `code/k8s/apps/woodpecker/values.yaml`
configure Gitea integration:

```yaml
server:
  env:
    WOODPECKER_HOST: "https://ci.apps.home.lab"
    WOODPECKER_GITEA: "true"
    WOODPECKER_GITEA_URL: "https://gitea.apps.home.lab"
    WOODPECKER_GITEA_SKIP_VERIFY: "true"
    WOODPECKER_OPEN: "true"
  extraSecretNamesForEnvFrom:
    - woodpecker-gitea-credentials
    - woodpecker-secret
```

The `woodpecker-gitea-credentials` secret must contain:
- `WOODPECKER_GITEA_CLIENT` - OAuth2 client ID
- `WOODPECKER_GITEA_SECRET` - OAuth2 client secret

The `woodpecker-secret` secret must contain:
- `WOODPECKER_AGENT_SECRET` - shared secret for server-agent RPC

### Setup Steps

#### Step 1: Create a Gitea OAuth2 Application

1. Log in to Gitea at `https://gitea.apps.home.lab` as an admin.
2. Navigate to **Site Administration > Applications** (or
   **User Settings > Applications** for user-scoped OAuth).
3. Create a new OAuth2 application:
   - **Application Name**: `Woodpecker CI`
   - **Redirect URI**: `https://ci.apps.home.lab/authorize`
4. Copy the **Client ID** and **Client Secret**.

#### Step 2: Generate the Agent Secret

```bash
# Generate a random 32-byte hex string for server-agent communication
openssl rand -hex 32
```

#### Step 3: Create and Seal the Secrets

```bash
# Gitea OAuth credentials
kubectl create secret generic woodpecker-gitea-credentials \
  --from-literal=WOODPECKER_GITEA_CLIENT='<gitea-oauth-client-id>' \
  --from-literal=WOODPECKER_GITEA_SECRET='<gitea-oauth-client-secret>' \
  --namespace=woodpecker \
  --dry-run=client -o yaml > /tmp/gitea-oauth.yaml

kubeseal --format=yaml \
  --controller-name=sealed-secrets \
  --controller-namespace=kube-system \
  < /tmp/gitea-oauth.yaml \
  > code/k8s/apps/woodpecker/sealed-secrets/gitea-oauth.yaml

# Woodpecker agent secret
kubectl create secret generic woodpecker-secret \
  --from-literal=WOODPECKER_AGENT_SECRET='<generated-hex-string>' \
  --namespace=woodpecker \
  --dry-run=client -o yaml > /tmp/woodpecker-secret.yaml

kubeseal --format=yaml \
  --controller-name=sealed-secrets \
  --controller-namespace=kube-system \
  < /tmp/woodpecker-secret.yaml \
  > code/k8s/apps/woodpecker/sealed-secrets/woodpecker-secret.yaml

# Clean up plaintext files
rm /tmp/gitea-oauth.yaml /tmp/woodpecker-secret.yaml
```

#### Step 4: Verify the Integration

1. Open Woodpecker CI at `https://ci.apps.home.lab`.
2. Click **Login**. You should be redirected to Gitea for OAuth.
3. Authorize the Woodpecker application in Gitea.
4. After redirect back to Woodpecker, your Gitea repositories should
   appear for activation.
5. Activate a repository and push a `.woodpecker.yml` pipeline file.
6. Verify the pipeline runs successfully.

---

## 4. Sealed Secrets Workflow

All integration credentials in this stack are managed as Sealed Secrets.
The workflow is:

1. **Create a plaintext secret** using `kubectl create secret ... --dry-run=client -o yaml`
2. **Seal it** with `kubeseal` (which encrypts against the cluster's Sealed Secrets controller public key)
3. **Commit the SealedSecret** YAML to the repository (safe to store in Git)
4. **Apply or let ArgoCD sync** the SealedSecret to the cluster
5. The Sealed Secrets controller **decrypts** it into a regular Kubernetes Secret

### Template Files

| Template | Path | Secret Name | Namespace |
|----------|------|-------------|-----------|
| GitLab API Token | `code/k8s/apps/jenkins/sealed-secrets/gitlab-api-token.yaml` | `gitlab-api-token` | `jenkins` |
| Harbor Credentials | `code/k8s/apps/jenkins/sealed-secrets/harbor-credentials.yaml` | `harbor-credentials` | `jenkins` |
| Gitea OAuth | `code/k8s/apps/woodpecker/sealed-secrets/gitea-oauth.yaml` | `woodpecker-gitea-credentials` | `woodpecker` |
| Woodpecker Agent | `code/k8s/apps/woodpecker/sealed-secrets/woodpecker-secret.yaml` | `woodpecker-secret` | `woodpecker` |

### Important Notes

- **Never commit plaintext secrets** to the repository.
- SealedSecrets are **cluster-scoped**: a sealed secret encrypted for
  one cluster cannot be decrypted by a different cluster.
- If you replace the Sealed Secrets controller or its key pair, you
  must re-seal all secrets.
- Back up the Sealed Secrets controller key pair for disaster recovery:
  ```bash
  kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key \
    -o yaml > sealed-secrets-key-backup.yaml
  ```
  Store this backup **outside** the Git repository in a secure location.
