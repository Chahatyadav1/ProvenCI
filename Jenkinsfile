pipeline {
    agent {
        kubernetes {
            yamlFile 'jenkins/pod-template.yaml'
        }
    }
    options {
        timestamps()
        disableConcurrentBuilds()
        timeout(time: 30, unit: 'MINUTES')
    }

    environment {
        REGISTRY            = 'docker.io/chahatyadav1/sscsp'
        IMAGE_TAG           = "${env.GIT_COMMIT.take(8)}"
        IMAGE_REF           = "${REGISTRY}:${IMAGE_TAG}"

        KMS_ARN             = credentials('kms-arn')
        SONAR_TOKEN         = credentials('sonarqube-token')
        SLACK_WEBHOOK       = credentials('slack-webhook-url')

        COSIGN_EXPERIMENTAL = '1'
    }

    stages {

        stage('Build Image') {
            steps {
                container('docker') {
                    sh '''
                        docker build -t ${IMAGE_REF} .
                        docker save ${IMAGE_REF} -o image.tar
                    '''
                }
            }
        }

        stage('Filesystem / Image Scan — Trivy') {
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
            steps {
                container('docker') {
                    withCredentials([usernamePassword(credentialsId: 'docker-creds', usernameVariable: 'DOCKER_USER', passwordVariable: 'DOCKER_PASS')]) {
                        sh '''
                            echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin
                            docker push ${IMAGE_REF}
                        '''
                    }
                }
            }
        }

        stage('Get Image Digest') {
            steps {
                container('crane') {
                    script {
                        env.IMAGE_DIGEST = sh(
                            script: "crane digest ${IMAGE_REF}",
                            returnStdout: true
                        ).trim()
                        echo "Digest:  ${env.IMAGE_DIGEST}"
                        echo "Image:   ${IMAGE_REF}@${env.IMAGE_DIGEST}"
                    }
                }
            }
        }

        stage('Generate SBOM — Syft') {
            steps {
                container('syft') {
                    sh '''
                        syft ${IMAGE_REF} \
                          --source-name ${IMAGE_REF} \
                          -o spdx-json=sbom.spdx.json

                        # Validate spdxVersion is present and correct before attesting
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
            steps {
                container('cosign') {
                    withCredentials([usernamePassword(credentialsId: 'docker-creds', usernameVariable: 'DOCKER_USER', passwordVariable: 'DOCKER_PASS')]) {
                        sh '''
                            echo "$DOCKER_PASS" | cosign login docker.io -u "$DOCKER_USER" --password-stdin
                            cosign sign \
                              --yes \
                              --key awskms://${KMS_ARN} \
                              ${IMAGE_REF}@${IMAGE_DIGEST}
                        '''
                    }
                }
            }
        }

        stage('Attest SBOM — Cosign') {
            steps {
                container('cosign') {
                    withCredentials([usernamePassword(credentialsId: 'docker-creds', usernameVariable: 'DOCKER_USER', passwordVariable: 'DOCKER_PASS')]) {
                        sh '''
                            echo "$DOCKER_PASS" | cosign login docker.io -u "$DOCKER_USER" --password-stdin
                            cosign attest \
                              --yes \
                              --predicate sbom.spdx.json \
                              --type https://spdx.dev/Document \
                              --key awskms://${KMS_ARN} \
                              ${IMAGE_REF}@${IMAGE_DIGEST}
                        '''
                    }
                }
            }
        }

stage('Generate + Attach SLSA Provenance') {
    steps {
        container('cosign') {
            withCredentials([usernamePassword(credentialsId: 'docker-creds', usernameVariable: 'DOCKER_USER', passwordVariable: 'DOCKER_PASS')]) {
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
    "buildStartedOn":  "${BUILD_TIMESTAMP}",
    "buildFinishedOn": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  }
}
EOF
                    cosign attest \
                      --yes \
                      --predicate provenance.json \
                      --type slsaprovenance \
                      --key awskms://${KMS_ARN} \
                      ${IMAGE_REF}@${IMAGE_DIGEST}
                '''
            }
        }
    }
}
        stage('Update GitOps Repo (ArgoCD Trigger)') {
            steps {
                container('git') {
                    withCredentials([string(credentialsId: 'GitHub-token-text', variable: 'GITHUB_TOKEN')]) {
                        sh '''
                            git clone https://${GITHUB_TOKEN}@github.com/Chahatyadav1/ProvenCI.git gitops-config

                            cd gitops-config

                            yq -i '.spec.template.spec.containers[0].image = "'"${IMAGE_REF}"'"' \
                              apps/slsa-demo-app/deployment.yaml

                            git config user.email "jenkins@company.com"
                            git config user.name  "jenkins"

                            git commit -am "deploy: ${IMAGE_TAG}" || true
                            git push origin main
                        '''
                    }
                }
            }
        }
    }

    post {
        success {
            sh '''
                curl -X POST \
                  -H "Content-type: application/json" \
                  --data "{\"text\":\"✅ Pipeline succeeded — ${IMAGE_REF} signed, attested and deployed\"}" \
                  $SLACK_WEBHOOK
            '''
        }
        failure {
            sh '''
                curl -X POST \
                  -H "Content-type: application/json" \
                  --data "{\"text\":\"❌ Pipeline failed — ${IMAGE_REF}. Check Jenkins logs.\"}" \
                  $SLACK_WEBHOOK
            '''
        }
        always {
            archiveArtifacts artifacts: 'sbom.spdx.json, provenance.json'
            cleanWs()
        }
    }
}