APP_VERSION ?= $(shell git describe --abbrev=5 --dirty --tags --always)
BINDIR ?= $(PWD)/bin
CHARTDIR ?= $(PWD)/charts

OS ?= $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH ?= amd64

PATH := $(BINDIR):$(PATH)
SHELL := env 'PATH=$(PATH)' /bin/sh

HELM ?= helm

.PHONY: charts
charts:
	yq w -i $(CHARTDIR)/stack/Chart.yaml version "$(APP_VERSION)"
	yq w -i $(CHARTDIR)/stack/Chart.yaml appVersion "$(APP_VERSION)"
	yq w -i $(CHARTDIR)/stack/values.yaml nginx-ingress.defaultBackend.image.tag "$(APP_VERSION:v%=%)"
	yq w -i $(CHARTDIR)/stack/values.yaml git-webhook.image.tag "$(APP_VERSION:v%=%)"
	yq w -i $(CHARTDIR)/wordpress-site/Chart.yaml version "$(APP_VERSION)"
	yq w -i $(CHARTDIR)/wordpress-site/Chart.yaml appVersion "$(APP_VERSION)"

lint:
	$(HELM) version
	$(HELM) repo add mysql-operator https://presslabs.github.io/charts
	$(HELM) repo add wordpress-operator https://presslabs.github.io/charts
	$(HELM) repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
	$(HELM) repo add kube-prometheus-stack https://prometheus-community.github.io/helm-charts
	$(HELM) repo add jetstack https://charts.jetstack.io
	$(HELM) repo add kubernetes-charts https://charts.helm.sh/stable
	$(HELM) repo update
	$(HELM) repo list
	$(HELM) lint charts/stack
	$(HELM) lint charts/wordpress-site --set 'site.domains[0]=example.com'
	$(HELM) dep build charts/stack
	$(HELM) dep build charts/wordpress-site
	make -C git-webhook lint

dependencies:
	test -d $(BINDIR) || mkdir $(BINDIR)
	# install ginkgo
	GOBIN=$(BINDIR) go get -u github.com/onsi/ginkgo/ginkgo@v1.15.0
	@# install golangci-lint
	curl -sfL https://install.goreleaser.com/github.com/golangci/golangci-lint.sh | BINARY=golangci-lint bash -s -- -b $(BINDIR) v1.37.1
	@# install yq
	curl -sfL https://github.com/mikefarah/yq/releases/download/3.3.2/yq_$(OS)_$(ARCH) -o $(BINDIR)/yq
	chmod +x $(BINDIR)/yq

	@# just ignore the go.mod
	git checkout go.mod go.sum

test:
	make -C git-webhook test


define getVersion
$(shell python3 -c "import yaml; print([x['version'] for x in yaml.load(open('charts/stack/requirements.lock', 'r'), Loader=yaml.BaseLoader)['dependencies'] if x['name'] == '$1'  ][0])")
endef

MANIFESTS_DIR ?= deploy/manifests
CRDS_DIR ?= $(MANIFESTS_DIR)/crds

MYSQL_OPERATOR_TAG ?= v$(call getVersion,mysql-operator)
WORDPRESS_OPERATOR_TAG ?= v$(call getVersion,wordpress-operator)
PROM_VERSION ?= v0.45.0

.PHONY: collect-crds
collect-crds:
	$(info ---- WORDPRESS_OPERATOR_TAG = $(WORDPRESS_OPERATOR_TAG))
	$(info ---- MYSQL_OPERATOR_TAG = $(MYSQL_OPERATOR_TAG))

	@rm -rf $(CRDS_DIR)/*

	@# wordpress operator
	kustomize build "github.com/presslabs/wordpress-operator/config?ref=$(WORDPRESS_OPERATOR_TAG)" > $(CRDS_DIR)/wordpress.yaml

	@# mysql operator
	wget https://raw.githubusercontent.com/presslabs/mysql-operator/$(MYSQL_OPERATOR_TAG)/config/crds/mysql.presslabs.org_mysqlclusters.yaml -O $(CRDS_DIR)/mysql_mysqlcluster.yaml
	wget https://raw.githubusercontent.com/presslabs/mysql-operator/$(MYSQL_OPERATOR_TAG)/config/crds/mysql.presslabs.org_mysqlbackups.yaml -O $(CRDS_DIR)/mysql_mysqlbackup.yaml
	wget https://raw.githubusercontent.com/presslabs/mysql-operator/$(MYSQL_OPERATOR_TAG)/config/crds/mysql.presslabs.org_mysqldatabases.yaml -O $(CRDS_DIR)/mysql_database.yaml
	wget https://raw.githubusercontent.com/presslabs/mysql-operator/$(MYSQL_OPERATOR_TAG)/config/crds/mysql.presslabs.org_mysqlusers.yaml -O $(CRDS_DIR)/mysql_user.yaml

	@# Prometheus
	wget https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/${PROM_VERSION}/example/prometheus-operator-crd/monitoring.coreos.com_alertmanagerconfigs.yaml -O- > $(CRDS_DIR)/prometheus.yaml
	wget https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/${PROM_VERSION}/example/prometheus-operator-crd/monitoring.coreos.com_podmonitors.yaml -O- >> $(CRDS_DIR)/prometheus.yaml
	wget https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/${PROM_VERSION}/example/prometheus-operator-crd/monitoring.coreos.com_prometheuses.yaml  -O- >> $(CRDS_DIR)/prometheus.yaml
	wget https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/${PROM_VERSION}/example/prometheus-operator-crd/monitoring.coreos.com_prometheusrules.yaml -O- >> $(CRDS_DIR)/prometheus.yaml
	wget https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/${PROM_VERSION}/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml -O- >> $(CRDS_DIR)/prometheus.yaml
	wget https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/${PROM_VERSION}/example/prometheus-operator-crd/monitoring.coreos.com_thanosrulers.yaml -O- >> $(CRDS_DIR)/prometheus.yaml

	yq d -d'*' -i $(CRDS_DIR)/prometheus.yaml status

	@# keep 00-crds.yaml for backward compatibility reasons
	rm -f $(MANIFESTS_DIR)/00-crds.yaml
	for file in $(CRDS_DIR)/* ; do \
		echo "---" >> $(MANIFESTS_DIR)/00-crds.yaml; \
		cat $${file} >> $(MANIFESTS_DIR)/00-crds.yaml; \
	done;

before-push: collect-crds lint
	helm dep update charts/stack/
	go mod tidy
