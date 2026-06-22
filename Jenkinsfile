
pipeline {
agent {
kubernetes {
yamlFile 'jenkins/pod-template.yaml'
}
}

```
options {
    timestamps()
    disableConcurrentBuilds()
    timeout(time: 30, unit: 'MINUTES')
}

environment {
    REGISTRY            = "docker.io/chahatyadav1/sscsp"
    IMAGE_TAG           = "${env.GIT_COMMIT.take(8)}"
    IMAGE_REF           = "${REGISTRY}:${IMAGE_TAG}"
    
    KMS_ARN             = credentials('kms-arn')
    SONAR_TOKEN         = credentials('sonarqube-token')
    REGISTRY_CREDS      = credentials('container-registry-creds')
    SLACK_WEBHOOK       = credentials('slack-webhook-url')

    COSIGN_EXPERIMENTAL = "1"
}

stages {

        stage('SAST - SonarQube') {
            steps {
                container('sonar-scanner'){
                sh 'sleep 5s'
                withSonarQubeEnv('SONAR_TOKEN') {
                    sh 'echo "DEBUG SONAR_HOST_URL=${SONAR_HOST_URL}"'
                    sh """$SONAR_SCANNER_HOME/bin/sonar-scanner \
                        -Dsonar.projectKey=World-Countries-Project \
                        -Dsonar.sources=app.js \
                        -Dsonar.javascript.lcov.reportPaths=./coverage/lcov.info \
                        -Dsonar.host.url=$SONAR_HOST_URL"""
                }
            }
        }
    }


    //             stage('OWASP Dependency Check') {
    //                 environment {
    //                     NVD_API_KEY = credentials('nvd-api-key')
    //                 }
    //                 steps {
    //                     container('owasp-dependency-check'){
    //                     dependencyCheck additionalArguments: """
    //                         --scan './'
    //                         --out './'
    //                         --format 'ALL'
    //                         --disableYarnAudit
    //                         --prettyPrint
    //                         --suppression dependency-check-suppression.xml
    //                         --nvdApiKey $NVD_API_KEY
    //                     """, odcInstallation: 'OWASP'

    //                     dependencyCheckPublisher(
    //                         failedTotalCritical: 1,
    //                         pattern: 'dependency-check-report.xml',
    //                         stopBuild: false
    //                     )
    //                 }
    //             }
    //         }

    //     post {
    //         always {
    //             archiveArtifacts(
    //                 artifacts: 'dependency-check-report.json',
    //                 allowEmptyArchive: true
    //             )
    //         }
    //     }
    // }

    stage('Build Image') {
        steps {
            container('docker') {
                    sh 'docker build -t ${IMAGE_REF} .'
                sh '''
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
                container(docker){
                withCredentials([usernamePassword(credentialsId: 'docker-creds', usernameVariable: 'DOCKER_USER', passwordVariable: 'DOCKER_PASS')]) {
                    sh '''
                        echo "$DOCKER_PASS" | docker login -u "$DOCKER_USER" --password-stdin
                        docker push ${IMAGE_REF}
                    '''
                }
            }
        }
    }

    stage('Generate SBOM — Syft') {
        steps {
            container('syft') {
                sh '''
                    syft ${IMAGE_REF} \
                      -o spdx-json > sbom.spdx.json
                '''
            }
        }

        post {
            always {
                archiveArtifacts artifacts: 'sbom.spdx.json'
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

    stage('Sign Image — Cosign (Keyless)') {
        steps {
            container('cosign') {
                 withCredentials([usernamePassword(credentialsId: 'docker-creds', usernameVariable: 'DOCKER_USER', passwordVariable: 'DOCKER_PASS')]) {
                sh '''
                    cosign sign --key awskms:///$KMS_ARN         
                '''
            }
        }
    }
}

    stage('Attest SBOM — Cosign') {
        steps {
            container('cosign') {
                sh '''
                    cosign attest \
                      --yes \
                      --predicate sbom.spdx.json \
                      --type spdx \
                      ${IMAGE_REF}
                '''
            }
        }
    }

    stage('Generate + Attach SLSA Provenance') {
        steps {
            container('cosign') {
                sh '''
                    cosign attest \
                      --yes \
                      --predicate provenance.json \
                      --type slsaprovenance \
                      ${IMAGE_REF}
                '''
            }
        }
    }

    stage('Update Image Tag'){
        steps{
            sh ''
        }
    }
    stage('Update GitOps Repo (ArgoCD Trigger)') {
        steps {
            container('git') {
                sh '''
                    git clone https://github.com/your-org/gitops-config.git

                    cd gitops-config

                    yq -i '.spec.template.spec.containers[0].image = "'"${IMAGE_REF}"'"' \
                      apps/slsa-demo-app/deployment.yaml

                    git config user.email "jenkins@company.com"
                    git config user.name "jenkins"

                    git commit -am "deploy: ${IMAGE_TAG}" || true
                    git push origin main
                '''
            }
        }
    }
}

post {

    success {
        sh '''
            curl -X POST \
              -H "Content-type: application/json" \
              --data "{\"text\":\" Pipeline succeeded - ${IMAGE_REF} signed, attested and deployed\"}" \
              $SLACK_WEBHOOK
        '''
    }

    failure {
        sh '''
            curl -X POST \
              -H "Content-type: application/json" \
              --data "{\"text\":\" Pipeline failed - ${IMAGE_REF}. Check Jenkins logs.\"}" \
              $SLACK_WEBHOOK
        '''
    }

    always {
        cleanWs()
    }
}
```


