ifndef MODULE_VERSION
    include .version
endif

# Module Name used for bundling the OCI Image and later on for referencing in the Kyma Modules
MODULE_NAME ?= nats

# Lint issue category
CATEGORY = "default"

# Operating system architecture
OS_ARCH ?= $(shell uname -m)

# Operating system type
OS_TYPE ?= $(shell uname)

# Module Registry used for pushing the image
MODULE_REGISTRY_PORT ?= 8888
MODULE_REGISTRY ?= op-kcp-registry.localhost:$(MODULE_REGISTRY_PORT)/unsigned

# Image URL to use all building/pushing image targets
IMG_REGISTRY_PORT ?= $(MODULE_REGISTRY_PORT)
IMG_REGISTRY ?= op-skr-registry.localhost:$(IMG_REGISTRY_PORT)/unsigned/manager-images
IMG ?= $(IMG_REGISTRY)/$(MODULE_NAME)-manager:$(MODULE_VERSION)

## Image URL to use all building/pushing image targets
#IMG ?= controller:latest
# ENVTEST_K8S_VERSION refers to the version of kubebuilder assets to be downloaded by envtest binary.
ENVTEST_K8S_VERSION = 1.27.1

# VERIFY_IGNORE is a grep pattern to exclude files and directories from verification
VERIFY_IGNORE := /vendor\|/automock

# FILES_TO_CHECK is a command used to determine which files should be verified
FILES_TO_CHECK = find . -type f -name "*.go" | grep -v "$(VERIFY_IGNORE)"
# DIRS_TO_CHECK is a command used to determine which directories should be verified
DIRS_TO_CHECK = go list ./... | grep -v "$(VERIFY_IGNORE)"
# DIRS_TO_IGNORE is a command used to determine which directories should not be verified
DIRS_TO_IGNORE = go list ./... | grep "$(VERIFY_IGNORE)"

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# Credentials used for authenticating into the module registry
# see `kyma alpha mod create --help for more info`

# This will change the flags of the `kyma alpha module create` command in case we spot credentials
# Otherwise we will assume http-based local registries without authentication (e.g. for k3d)
ifneq (,$(PROW_JOB_ID))
GCP_ACCESS_TOKEN=$(shell gcloud auth application-default print-access-token)
MODULE_CREATION_FLAGS=--registry $(MODULE_REGISTRY) --module-archive-version-overwrite -c oauth2accesstoken:$(GCP_ACCESS_TOKEN)
else ifeq (,$(MODULE_CREDENTIALS))
# when built locally we should not include security content.
MODULE_CREATION_FLAGS=--registry $(MODULE_REGISTRY) --module-archive-version-overwrite --insecure --sec-scanners-config=sec-scanners-config-local.yaml
else
MODULE_CREATION_FLAGS=--registry $(MODULE_REGISTRY) --module-archive-version-overwrite -c $(MODULE_CREDENTIALS)
endif

# Setting SHELL to bash allows bash commands to be executed by recipes.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

.PHONY: all
all: build

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Development

.PHONY: manifests
manifests: controller-gen ## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects.
	$(CONTROLLER_GEN) rbac:roleName=manager-role crd webhook paths="./..." output:crd:artifacts:config=config/crd/bases
	$(MAKE) crd-docs-gen

.PHONY: generate
generate: go-gen controller-gen ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

.PHONY: vet
vet: ## Run go vet against code.
	go vet ./...

.PHONY: generate-and-test
generate-and-test: vendor manifests generate fmt imports vet lint test;

.PHONY: test
test: envtest ## Run only tests.
	KUBEBUILDER_ASSETS="$(shell $(ENVTEST) use $(ENVTEST_K8S_VERSION) --bin-dir $(LOCALBIN) -p path)" go test ./... -coverprofile cover.out


.PHONY: lint
lint: golangci_lint
	$(LOCALBIN)/golangci-lint run

.PHONY: lint-fix
lint-fix: golangci_lint
	$(LOCALBIN)/golangci-lint run --fix

.PHONY: lint-compact
lint-compact: ## Check lint issues using `golangci-lint` in compact result format
	$(LOCALBIN)/golangci-lint run --print-issued-lines=false

.PHONY: lint-report
lint-report: golangci_lint ## Check lint issues using `golangci-lint` then export them to a file, then print the list of linters used
	$(LOCALBIN)/golangci-lint run --issues-exit-code 0 --out-format json > ./lint-report.json

.PHONY: lint-report-issue-category
lint-report-issue-category: ## Get lint issues categories
	make lint-report-clean
	make lint-report
	cat ./lint-report.json | jq '.Issues[].FromLinter' | jq -s 'map({(.):1})|add|keys_unsorted'

.PHONY: lint-report-get-category
lint-report-get-category: ## Get lint issues by category
	cat ./lint-report.json | jq --arg CATEGORY $$CATEGORY '.Issues[] | select(.FromLinter==$$CATEGORY)'

.PHONY: lint-report-clean
lint-report-clean: ## Clean lint report
	rm -f ./lint-report.json

##@ Build

.PHONY: build
build: manifests generate fmt vet
	go build -o bin/manager cmd/main.go

.PHONY: run
run: manifests generate fmt vet ## Run a controller from your host.
	go run ./cmd/main.go

.PHONY: vendor
vendor:
	go mod vendor

# If you wish built the manager image targeting other platforms you can use the --platform flag.
# (i.e. docker build --platform linux/arm64 ). However, you must enable docker buildKit for it.
# More info: https://docs.docker.com/develop/develop-images/build_enhancements/
.PHONY: docker-build
docker-build: test ## Build docker image with the manager.
	docker build -t ${IMG} .

.PHONY: docker-push
docker-push: ## Push docker image with the manager.
	docker push ${IMG}

# PLATFORMS defines the target platforms for  the manager image be build to provide support to multiple
# architectures. (i.e. make docker-buildx IMG=myregistry/mypoperator:0.0.1). To use this option you need to:
# - able to use docker buildx . More info: https://docs.docker.com/build/buildx/
# - have enable BuildKit, More info: https://docs.docker.com/develop/develop-images/build_enhancements/
# - be able to push the image for your registry (i.e. if you do not inform a valid value via IMG=<myregistry/image:<tag>> then the export will fail)
# To properly provided solutions that supports more than one platform you should use this option.
PLATFORMS ?= linux/arm64,linux/amd64,linux/s390x,linux/ppc64le
.PHONY: docker-buildx
docker-buildx: test ## Build and push docker image for the manager for cross-platform support
	# copy existing Dockerfile and insert --platform=${BUILDPLATFORM} into Dockerfile.cross, and preserve the original Dockerfile
	sed -e '1 s/\(^FROM\)/FROM --platform=\$$\{BUILDPLATFORM\}/; t' -e ' 1,// s//FROM --platform=\$$\{BUILDPLATFORM\}/' Dockerfile > Dockerfile.cross
	- docker buildx create --name project-v3-builder
	docker buildx use project-v3-builder
	- docker buildx build --push --platform=$(PLATFORMS) --tag ${IMG} -f Dockerfile.cross .
	- docker buildx rm project-v3-builder
	rm Dockerfile.cross

##@ Deployment

ifndef ignore-not-found
  ignore-not-found = false
endif

.PHONY: install
install: manifests kustomize ## Install CRDs into the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

.PHONY: uninstall
uninstall: manifests kustomize ## Uninstall CRDs from the K8s cluster specified in ~/.kube/config. Call with ignore-not-found=true to ignore resource not found errors during deletion.
	$(KUSTOMIZE) build config/crd | kubectl delete --ignore-not-found=$(ignore-not-found) -f -

.PHONY: deploy
deploy: manifests kustomize ## Deploy controller to the K8s cluster specified in ~/.kube/config.
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default | kubectl apply -f -

.PHONY: render-manifest
render-manifest: manifests kustomize
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default > nats-manager.yaml

.PHONY: undeploy
undeploy: ## Undeploy controller from the K8s cluster specified in ~/.kube/config. Call with ignore-not-found=true to ignore resource not found errors during deletion.
	$(KUSTOMIZE) build config/default | kubectl delete --ignore-not-found=$(ignore-not-found) -f -

##@ Build Dependencies

## Location to install dependencies to
LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

##@ Module

.PHONY: module-image
module-image: docker-build docker-push ## Build the Module Image and push it to a registry defined in IMG_REGISTRY
	echo "built and pushed module image $(IMG)"

DEFAULT_CR ?= $(shell pwd)/config/samples/default.yaml

.PHONY: configure-git-origin
configure-git-origin:
#	test-infra does not include origin remote in the .git directory.
#	the CLI is looking for the origin url in the .git dir so first we need to be sure it's not empty
	@git remote | grep '^origin$$' -q || \
		git remote add origin https://github.com/kyma-project/nats-manager

## Tool Binaries
KUSTOMIZE ?= $(LOCALBIN)/kustomize
CONTROLLER_GEN ?= $(LOCALBIN)/controller-gen
ENVTEST ?= $(LOCALBIN)/setup-envtest

## Tool Versions
KUSTOMIZE_VERSION ?= v5.3.0
CONTROLLER_TOOLS_VERSION ?= v0.16.1
GOLANG_CI_LINT_VERSION ?= v2.1.6 # Keept this the same as in .github/workflows/codequality.yml

KUSTOMIZE_INSTALL_SCRIPT ?= "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh"
.PHONY: kustomize
kustomize: $(KUSTOMIZE) ## Download kustomize locally if necessary. If wrong version is installed, it will be removed before downloading.
$(KUSTOMIZE): $(LOCALBIN)
	@if test -x $(LOCALBIN)/kustomize && ! $(LOCALBIN)/kustomize version | grep -q $(KUSTOMIZE_VERSION); then \
		echo "$(LOCALBIN)/kustomize version is not expected $(KUSTOMIZE_VERSION). Removing it before installing."; \
		rm -rf $(LOCALBIN)/kustomize; \
	fi
	test -s $(LOCALBIN)/kustomize || { curl -Ss $(KUSTOMIZE_INSTALL_SCRIPT) | bash -s -- $(subst v,,$(KUSTOMIZE_VERSION)) $(LOCALBIN); }

.PHONY: controller-gen
controller-gen: $(CONTROLLER_GEN) ## Download controller-gen locally if necessary. If wrong version is installed, it will be overwritten.
$(CONTROLLER_GEN): $(LOCALBIN)
	test -s $(LOCALBIN)/controller-gen && $(LOCALBIN)/controller-gen --version | grep -q $(CONTROLLER_TOOLS_VERSION) || \
	GOBIN=$(LOCALBIN) go install sigs.k8s.io/controller-tools/cmd/controller-gen@$(CONTROLLER_TOOLS_VERSION)

.PHONY: envtest
envtest: $(ENVTEST) ## Download envtest-setup locally if necessary.
$(ENVTEST): $(LOCALBIN)
	test -s $(LOCALBIN)/setup-envtest || GOBIN=$(LOCALBIN) go install sigs.k8s.io/controller-runtime/tools/setup-envtest@latest

golangci_lint:
	test -s $(LOCALBIN)/golangci-lint && $(LOCALBIN)/golangci-lint version | grep -q $(GOLANG_CI_LINT_VERSION) || \
		GOBIN=$(LOCALBIN) go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@$(GOLANG_CI_LINT_VERSION)

go-gen:
	go generate ./...

.PHONY: fmt
fmt: ## Reformat files using `go fmt`
	go fmt $$($(DIRS_TO_CHECK))

imports: ## Optimize imports
	goimports -w -l $$($(FILES_TO_CHECK))

########## Kyma CLI ###########
KYMA_STABILITY ?= unstable

# $(call os_error, os-type, os-architecture)
define os_error
$(error Error: unsuported platform OS_TYPE:$1, OS_ARCH:$2; to mitigate this problem set variable KYMA with absolute path to kyma-cli binary compatible with your operating system and architecture)
endef

KYMA_FILE_NAME ?= $(shell ./hack/get_kyma_file_name.sh ${OS_TYPE} ${OS_ARCH})
KYMA ?= $(LOCALBIN)/kyma-$(KYMA_STABILITY)

.PHONY: kyma
kyma: $(LOCALBIN) $(KYMA) ## Download kyma CLI locally if necessary.
$(KYMA):
	#################################################################
	$(if $(KYMA_FILE_NAME),,$(call os_error, ${OS_TYPE}, ${OS_ARCH}))
	## Downloading Kyma CLI: https://storage.googleapis.com/kyma-cli-$(KYMA_STABILITY)/$(KYMA_FILE_NAME)
	test -f $@ || curl -s -Lo $(KYMA) https://storage.googleapis.com/kyma-cli-$(KYMA_STABILITY)/$(KYMA_FILE_NAME)
	chmod 0100 $(KYMA)
	${KYMA} version -c

# e2e testing is done here
.PHONY: e2e-setup
e2e-setup:
	go test -v ./e2e/setup/setup_test.go --tags=e2e

.PHONY: e2e-bench
e2e-bench:
	./e2e/scripts/natsbench.sh

.PHONY: e2e-nats-server
e2e-nats-server:
	./e2e/scripts/natsserver.sh

.PHONY: e2e-cleanup
e2e-cleanup:
	go test -v ./e2e/cleanup/cleanup_test.go --tags=e2e

.PHONY: e2e-only
e2e-only: e2e-setup e2e-bench e2e-nats-server e2e-cleanup

.PHONY: e2e
e2e: install docker-build docker-push deploy e2e-setup e2e-bench e2e-nats-server e2e-cleanup

TABLE_GEN ?= $(LOCALBIN)/table-gen
TABLE_GEN_VERSION ?= v0.0.0-20230523174756-3dae9f177ffd

.PHONY: tablegen
tablegen: $(TABLE_GEN) ## Download table-gen locally if necessary.
$(TABLE_GEN): $(LOCALBIN)
	test -s $(TABLE_GEN) || GOBIN=$(LOCALBIN) go install github.com/kyma-project/kyma/hack/table-gen@$(TABLE_GEN_VERSION)

.PHONY: crd-docs-gen
crd-docs-gen: tablegen ## Generates CRD spec into docs folder
	${TABLE_GEN} --crd-filename ./config/crd/bases/operator.kyma-project.io_nats.yaml --md-filename ./docs/user/02-configuration.md
