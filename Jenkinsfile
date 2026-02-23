// =============================================================================
// home-bootstrap CI Pipeline
// =============================================================================
// Implements Constitution Quality Gates:
//   1. Lint gate (ansible-lint, yamllint, tflint, shellcheck)
//   2. Validation gate (tofu validate, syntax checks)
//   3. Test gate (tofu test, smoke tests)
//   4. Plan gate (tofu plan review)
//   5. Security gate (detect-private-key, SOPS verification)
// =============================================================================

pipeline {
    agent { label 'jenkins-agent' }

    options {
        timeout(time: 30, unit: 'MINUTES')
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }

    environment {
        ANSIBLE_DIR = 'code/ansible'
        TOFU_DIR    = 'code/tofu'
        K8S_DIR     = 'code/k8s'
    }

    stages {
        stage('Lint Gate') {
            parallel {
                stage('ansible-lint') {
                    steps {
                        dir("${ANSIBLE_DIR}") {
                            sh 'ansible-lint'
                        }
                    }
                }
                stage('yamllint') {
                    steps {
                        sh "yamllint -c .yamllint.yml ${ANSIBLE_DIR}/ ${K8S_DIR}/"
                    }
                }
                stage('tflint') {
                    steps {
                        dir("${TOFU_DIR}") {
                            sh 'tflint --config .tflint.hcl'
                        }
                    }
                }
                stage('shellcheck') {
                    steps {
                        sh 'shellcheck code/scripts/*.sh tests/**/*.sh'
                    }
                }
            }
        }

        stage('Validation Gate') {
            steps {
                dir("${TOFU_DIR}/environments/prod") {
                    sh 'tofu init -backend=false'
                    sh 'tofu validate'
                }
            }
        }

        stage('Test Gate') {
            parallel {
                stage('tofu test') {
                    steps {
                        dir("${TOFU_DIR}/modules/proxmox-vm") {
                            sh 'tofu init -backend=false'
                            sh 'tofu test'
                        }
                    }
                }
                stage('ansible syntax-check') {
                    steps {
                        dir("${ANSIBLE_DIR}") {
                            sh 'ansible-playbook --syntax-check playbooks/*.yml'
                        }
                    }
                }
                stage('ansible lint tests') {
                    steps {
                        sh 'ansible-playbook --syntax-check tests/ansible/lint/*.yml'
                    }
                }
            }
        }

        stage('Plan Gate') {
            when {
                anyOf {
                    changeset "code/tofu/**"
                    changeset "code/ansible/**"
                }
            }
            steps {
                dir("${TOFU_DIR}/environments/prod") {
                    sh 'tofu plan -no-color -out=tfplan'
                    sh 'tofu show -no-color tfplan'
                }
            }
        }

        stage('Security Gate') {
            parallel {
                stage('No plaintext secrets') {
                    steps {
                        sh '''
                            if git log --all --diff-filter=A -p -- '*.enc.*' | grep -q 'password:.*[^E][^N][^C]'; then
                                echo "FAIL: Potential plaintext secrets detected"
                                exit 1
                            fi
                            echo "PASS: No plaintext secrets found"
                        '''
                    }
                }
                stage('Pre-commit hooks') {
                    steps {
                        sh 'pre-commit run detect-private-key --all-files'
                    }
                }
            }
        }
    }

    post {
        always {
            cleanWs()
        }
        success {
            echo 'All quality gates passed.'
        }
        failure {
            echo 'Quality gate failed. Check stage output for details.'
        }
    }
}
