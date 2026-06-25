pipeline {
    agent {
        kubernetes {
            yamlFile 'jenkins/pod-template.yaml'
            cloud 'eks-cloud'
        }
    }
    options {
        timestamps()
        disableConcurrentBuilds(abortPrevious: true)
        timeout(time: 30, unit: 'MINUTES')
    }

    environment {
        REGISTRY  = 'docker.io/chahatyadav1/dashboard'
        IMAGE_TAG = "${env.GIT_COMMIT?.take(8) ?: 'unknown'}"
        IMAGE_REF = "${REGISTRY}:${IMAGE_TAG}"
        KMS_ARN   = credentials('kms-arn')
    }

    stages {
        stage('Build Image') {
            when { branch 'dev' }
            steps {
                container('docker') {
                    sh '''
                        echo "Waiting for Docker daemon..."
                        until docker info > /dev/null 2>&1; do
                            echo "Docker not ready yet, retrying in 2s..."
                            sleep 2
                        done
                        echo "Docker daemon is ready"
                        docker build -t ${IMAGE_REF} .
                        docker save ${IMAGE_REF} -o image.tar
                    '''
                }
            }
        }

        stage('Filesystem / Image Scan — Trivy') {
            when { branch 'dev' }
            steps {
                container('trivy') {
                    sh '''
                        trivy image \
                          --input image.tar \
                          --severity HIGH,CRITICAL \
                          --exit-code 1 \
                          --format table
                    '''
                }
            }
        }

        stage('Push Docker Image') {
            when { branch 'dev' }
            steps {
                container('docker') {
                    withCredentials([usernamePassword(credentialsId: 'docker-creds',
                        usernameVariable: 'DOCKER_USER', passwordVariable: 'DOCKER_PASS')]) {
                        sh '''
                            echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin
                            docker push ${IMAGE_REF}
                        '''
                    }
                }
            }
        }

        stage('Get Image Digest') {
            when { branch 'dev' }
            steps {
                container('crane') {
                    script {
                        env.IMAGE_DIGEST = sh(
                            script: "crane digest ${IMAGE_REF}",
                            returnStdout: true
                        ).trim()
                        echo "Digest: ${env.IMAGE_DIGEST}"
                        echo "Image:  ${IMAGE_REF}@${env.IMAGE_DIGEST}"
                    }
                }
            }
        }

        stage('Generate SBOM — Syft') {
            when { branch 'dev' }
            steps {
                container('syft') {
                    sh '''
                        syft docker-archive:image.tar \
                          --source-name ${IMAGE_REF} \
                          -o spdx-json=sbom.spdx.json

                        SPDX_VER=$(grep -o '"spdxVersion":"SPDX-2.3"' sbom.spdx.json || true)
                        if [ -z "$SPDX_VER" ]; then
                            echo "ERROR: sbom.spdx.json is not SPDX-2.3 — aborting"
                            exit 1
                        fi
                        echo "SBOM validated: SPDX-2.3"
                    '''
                }
            }
        }

        stage('SBOM Vulnerability Scan — Grype') {
            when { branch 'dev' }
            steps {
                container('grype') {
                    sh '''
                        grype sbom:sbom.spdx.json \
                          --fail-on critical \
                          --output table
                    '''
                }
            }
        }

        stage('Sign Image — Cosign') {
            environment {
                AWS_REGION         = 'ap-south-1'
                AWS_DEFAULT_REGION = 'ap-south-1'
            }
            when { branch 'dev' }
            steps {
                container('cosign') {
                    withCredentials([usernamePassword(credentialsId: 'docker-creds',
                        usernameVariable: 'DOCKER_USER', passwordVariable: 'DOCKER_PASS')]) {
                        sh '''
                            echo "$DOCKER_PASS" | cosign login docker.io -u "$DOCKER_USER" --password-stdin
                            cosign sign --yes \
                              --key awskms:///${KMS_ARN} \
                              ${IMAGE_REF}@${IMAGE_DIGEST}
                        '''
                    }
                }
            }
        }

        stage('Attest SBOM — Cosign') {
            environment {
                AWS_REGION         = 'ap-south-1'
                AWS_DEFAULT_REGION = 'ap-south-1'
            }
            when { branch 'dev' }
            steps {
                container('cosign') {
                    withCredentials([usernamePassword(credentialsId: 'docker-creds',
                        usernameVariable: 'DOCKER_USER', passwordVariable: 'DOCKER_PASS')]) {
                        sh '''
                            echo "$DOCKER_PASS" | cosign login docker.io -u "$DOCKER_USER" --password-stdin
                            cosign attest \
                              --yes \
                              --predicate sbom.spdx.json \
                              --type https://spdx.dev/Document \
                              --key awskms:///${KMS_ARN} \
                              ${IMAGE_REF}@${IMAGE_DIGEST}
                        '''
                    }
                }
            }
        }

        stage('Generate + Attach SLSA Provenance') {
            environment {
                AWS_REGION         = 'ap-south-1'
                AWS_DEFAULT_REGION = 'ap-south-1'
            }
            when { branch 'dev' }
            steps {
                container('cosign') {
                    withCredentials([usernamePassword(credentialsId: 'docker-creds',
                        usernameVariable: 'DOCKER_USER', passwordVariable: 'DOCKER_PASS')]) {
                        sh '''
                            echo "$DOCKER_PASS" | cosign login docker.io -u "$DOCKER_USER" --password-stdin

                            cat <<EOF > provenance.json
{
  "buildType": "https://github.com/Chahatyadav1/ProvenCI",
  "builder": { "id": "https://jenkins.company.com" },
  "invocation": {
    "configSource": {
      "uri": "${GIT_URL}",
      "digest": { "sha1": "${GIT_COMMIT}" },
      "entryPoint": "Jenkinsfile"
    }
  },
  "metadata": {
    "buildStartedOn":  "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "buildFinishedOn": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  }
}
EOF
                            cosign attest \
                              --yes \
                              --predicate provenance.json \
                              --type slsaprovenance \
                              --key awskms:///${KMS_ARN} \
                              ${IMAGE_REF}@${IMAGE_DIGEST}
                        '''
                    }
                }
            }
        }

        stage('Update GitOps (ArgoCD Trigger)') {
            when { branch 'dev' }
            steps {
                container('git') {
                    withCredentials([string(credentialsId: 'github-token', variable: 'GITHUB_TOKEN')]) {
                        sh '''
                            git config --global --add safe.directory ${WORKSPACE}
                            cd ${WORKSPACE}

                            git config user.email "jenkins@company.com"
                            git config user.name "jenkins"
                            git remote set-url origin https://${GITHUB_TOKEN}@github.com/Chahatyadav1/ProvenCI.git
                            git fetch origin dev
                            git checkout dev
                            git reset --hard origin/dev

                            yq -i '.spec.template.spec.containers[0].image = "'"${IMAGE_REF}"'"' \
                              k8s/deployment.yaml

                            git add k8s/deployment.yaml
                            git diff --cached --quiet || \
                              git commit -m "ci: update image to ${IMAGE_REF} [skip ci]"
                            git push origin dev
                        '''
                    }
                }
            }
        }

        stage('K8S - Raise PR') {
            when { branch 'dev' }
            steps {
                container('git') {
                    withCredentials([string(credentialsId: 'github-token', variable: 'GITHUB_TOKEN')]) {
                        sh '''
                            export GH_TOKEN=${GITHUB_TOKEN}

                            EXISTING=$(gh pr list \
                              --repo Chahatyadav1/ProvenCI \
                              --head dev --base main \
                              --json number --jq length)

                            if [ "$EXISTING" -gt 0 ]; then
                                echo "PR already exists — skipping creation"
                            else
                                gh pr create \
                                  --repo Chahatyadav1/ProvenCI \
                                  --title "ci: update image tag — build ${BUILD_ID}" \
                                  --body "Updates image to ${IMAGE_REF} for build ${BUILD_ID}" \
                                  --head dev \
                                  --base main
                            fi
                        '''
                    }
                }
            }
        }

        stage('Manual Approval') {
            when { branch 'main' }
            steps {
                input(
                    message: 'Is the PR merged, ArgoCD deployed and synced?',
                    ok: 'Yes — ship it',
                    cancel: 'No'
                )
            }
        }
    }

    post {
        success {
            slackSend(
                channel: '#argocd-notification',
                color: 'good',
                tokenCredentialId: 'slack-bot-token',
                message: "Pipeline succeeded — ${IMAGE_REF} signed, attested and deployed"
            )
        }
        failure {
            slackSend(
                channel: '#argocd-notification',
                color: 'danger',
                tokenCredentialId: 'slack-bot-token',
                message: "Pipeline failed — ${IMAGE_REF}. Check Jenkins logs."
            )
        }
        always {
            archiveArtifacts artifacts: 'sbom.spdx.json,provenance.json',
                             allowEmptyArchive: true
            cleanWs()
        }
    }
}