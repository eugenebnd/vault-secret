export GO111MODULE=on

# Current Operator version
VERSION ?= 1.0.1
# Default bundle image tag
BUNDLE_IMG ?= controller-bundle:$(VERSION)
# Default version used when preparing for a release, image building and pushing
RELEASE_NAME ?= $(CIRCLE_TAG)
GOOS ?= linux
GOARCH ?= amd64

# Options for 'bundle-build'
ifneq ($(origin CHANNELS), undefined)
BUNDLE_CHANNELS := --channels=$(CHANNELS)
endif
ifneq ($(origin DEFAULT_CHANNEL), undefined)
BUNDLE_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
endif
BUNDLE_METADATA_OPTS ?= $(BUNDLE_CHANNELS) $(BUNDLE_DEFAULT_CHANNEL)

# Image URL to use all building/pushing image targets
IMG ?= vault-secret:test
# Produce CRDs that work back to Kubernetes 1.11 (no version conversion)
CRD_OPTIONS ?= "crd:trivialVersions=true,crdVersions=v1"

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

all: manager

# Run tests
test: generate fmt vet manifests
	go test ./... -coverprofile cover.out

# Build manager binary
manager: generate fmt vet
	CGO_ENABLED=0 GOOS=$(GOOS) GOARCH=$(GOARCH) GO111MODULE=on go build -o bin/manager main.go

# Run against the configured Kubernetes cluster in ~/.kube/config
run: generate fmt vet manifests
	go run ./main.go

# Install CRDs into a cluster
install: manifests kustomize
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

# Uninstall CRDs from a cluster
uninstall: manifests kustomize
	$(KUSTOMIZE) build config/crd | kubectl delete -f -

# Deploy controller in the configured Kubernetes cluster in ~/.kube/config
deploy: manifests kustomize
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(IMG)
	$(KUSTOMIZE) build config/default | kubectl apply -f -

# Generate manifests e.g. CRD, RBAC etc.
manifests: controller-gen
	$(CONTROLLER_GEN) $(CRD_OPTIONS) rbac:roleName=manager-role webhook paths="./..." output:crd:artifacts:config=config/crd/bases

# Run go fmt against code
fmt:
	go fmt ./...

# Run go vet against code
vet:
	go vet ./...

# Generate code
generate: controller-gen
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

# Build the docker image
docker-build: test
	docker build . -t ${IMG}

# Push the docker image
docker-push:
	docker push ${IMG}

# find or download controller-gen
# download controller-gen if necessary
controller-gen:
ifeq (, $(shell which controller-gen))
	@{ \
	set -e ;\
	CONTROLLER_GEN_TMP_DIR=$$(mktemp -d) ;\
	cd $$CONTROLLER_GEN_TMP_DIR ;\
	go mod init tmp ;\
	go get sigs.k8s.io/controller-tools/cmd/controller-gen@v0.3.0 ;\
	rm -rf $$CONTROLLER_GEN_TMP_DIR ;\
	}
CONTROLLER_GEN=$(GOBIN)/controller-gen
else
CONTROLLER_GEN=$(shell which controller-gen)
endif

kustomize:
ifeq (, $(shell which kustomize))
	@{ \
	set -e ;\
	KUSTOMIZE_GEN_TMP_DIR=$$(mktemp -d) ;\
	cd $$KUSTOMIZE_GEN_TMP_DIR ;\
	go mod init tmp ;\
	go get sigs.k8s.io/kustomize/kustomize/v3@v3.5.4 ;\
	rm -rf $$KUSTOMIZE_GEN_TMP_DIR ;\
	}
KUSTOMIZE=$(GOBIN)/kustomize
else
KUSTOMIZE=$(shell which kustomize)
endif

# Generate bundle manifests and metadata, then validate generated files.
bundle: manifests
	operator-sdk generate kustomize manifests -q
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(IMG)
	kustomize build config/manifests | operator-sdk generate bundle -q --overwrite --version $(VERSION) $(BUNDLE_METADATA_OPTS)
	operator-sdk bundle validate ./bundle

# Build the bundle image.
bundle-build:
	docker build -f bundle.Dockerfile -t $(BUNDLE_IMG) .

## custom tasks
.PHONY: CI-prepare-release
CI-prepare-release:
	mkdir -p release/manifests/crds
	cp -a config/crd/bases/maupu.org_vaultsecrets.yaml release/manifests/crds
	cp -a config/doc-samples/* release/manifests/
	tar cfz release/vault-secret-manifests-$(RELEASE_NAME).tar.gz -C release manifests
	rm -rf release/manifests/
	sed -i -e "s/latest/$(RELEASE_NAME)/g" version/version.go
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GO111MODULE=on go build -a -o release/vault-secret-$(RELEASE_NAME)-linux-amd64 main.go
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 GO111MODULE=on go build -a -o release/vault-secret-$(RELEASE_NAME)-linux-arm64 main.go

.PHONY: CI-process-release
CI-process-release:
	@echo "Version to be released: $(CIRCLE_TAG)"
	ghr -t $(GITHUB_TOKEN) \
		-u $(CIRCLE_PROJECT_USERNAME) \
		-r $(CIRCLE_PROJECT_REPONAME) \
		-c $(CIRCLE_SHA1) \
		-n "Release v$(CIRCLE_TAG)" \
		-b "$(shell git log --format=%B -n1 $(CIRCLE_SHA1))" \
		-delete \
		$(CIRCLE_TAG) release/

.PHONY: CI-docker-build
CI-docker-build:
	docker build --build-arg=GOOS=$(GOOS) --build-arg=GOARCH=$(GOARCH) --no-cache . -t $(ORG_NAME)/$(PROJECT_NAME):$(RELEASE_NAME)

.PHONY: CI-docker-push
CI-docker-push:
	docker push $(ORG_NAME)/$(PROJECT_NAME):$(RELEASE_NAME)
