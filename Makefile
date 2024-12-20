LOCALBIN ?= $(shell pwd)/bin
export LOCALBIN
$(LOCALBIN):
	mkdir -p $(LOCALBIN)


HELM=helm
YQ=yq
TEMPLATES_DIR := charts
PROVIDER_TEMPLATES_DIR := $(TEMPLATES_DIR)/provider
export PROVIDER_TEMPLATES_DIR
CHARTS_PACKAGE_DIR ?= $(LOCALBIN)/charts
EXTENSION_CHARTS_PACKAGE_DIR ?= $(LOCALBIN)/charts/extensions
$(EXTENSION_CHARTS_PACKAGE_DIR): | $(LOCALBIN)
	mkdir -p $(EXTENSION_CHARTS_PACKAGE_DIR)
$(CHARTS_PACKAGE_DIR): | $(LOCALBIN)
	rm -rf $(CHARTS_PACKAGE_DIR)
	mkdir -p $(CHARTS_PACKAGE_DIR)

REGISTRY_NAME ?= hmc-local-registry
REGISTRY_PORT ?= 5001
REGISTRY_REPO ?= oci://127.0.0.1:$(REGISTRY_PORT)/charts
REGISTRY_IS_OCI = $(shell echo $(REGISTRY_REPO) | grep -q oci && echo true || echo false)

TEMPLATE_FOLDERS = $(patsubst $(TEMPLATES_DIR)/%,%,$(wildcard $(TEMPLATES_DIR)/*))

CHILD_VERSION=$(shell $(YQ) '.version' $(TEMPLATES_DIR)/motel-child/Chart.yaml)
REGIONAL_VERSION=$(shell $(YQ) '.version' $(TEMPLATES_DIR)/motel-regional/Chart.yaml)
USER_EMAIL=$(shell git config user.email)

REG_DOMAIN = $(USER)-reg.$(MOTEL_DNS)
MOTEL_STORAGE_NAME = motel-storage
MOTEL_STORAGE_NS = motel-storage

dev:
	mkdir -p dev

lint-chart-%:
	$(HELM) dependency update $(TEMPLATES_DIR)/$*
	$(HELM) lint --strict $(TEMPLATES_DIR)/$*

package-chart-%: lint-chart-%
	$(HELM) package --destination $(CHARTS_PACKAGE_DIR) $(TEMPLATES_DIR)/$*

.PHONY: helm-package
helm-package: $(CHARTS_PACKAGE_DIR) $(EXTENSION_CHARTS_PACKAGE_DIR)
	@make $(patsubst %,package-chart-%,$(TEMPLATE_FOLDERS))

.PHONY: helm-push
helm-push: helm-package
	@if [ ! $(REGISTRY_IS_OCI) ]; then \
	    repo_flag="--repo"; \
	fi; \
	for chart in $(CHARTS_PACKAGE_DIR)/*.tgz; do \
		base=$$(basename $$chart .tgz); \
		chart_version=$$(echo $$base | grep -o "v\{0,1\}[0-9]\+\.[0-9]\+\.[0-9].*"); \
		chart_name="$${base%-"$$chart_version"}"; \
		echo "Verifying if chart $$chart_name, version $$chart_version already exists in $(REGISTRY_REPO)"; \
		if $(REGISTRY_IS_OCI); then \
			chart_exists=$$($(HELM) pull $$repo_flag $(REGISTRY_REPO)/$$chart_name --version $$chart_version --destination /tmp 2>&1 | grep "not found" || true); \
		else \
			chart_exists=$$($(HELM) pull $$repo_flag $(REGISTRY_REPO) $$chart_name --version $$chart_version --destination /tmp 2>&1 | grep "not found" || true); \
		fi; \
		if [ -z "$$chart_exists" ]; then \
			echo "Chart $$chart_name version $$chart_version already exists in the repository."; \
		fi; \
		if $(REGISTRY_IS_OCI); then \
			echo "Pushing $$chart to $(REGISTRY_REPO)"; \
			$(HELM) push "$$chart" $(REGISTRY_REPO); \
		else \
			if [ ! $$REGISTRY_USERNAME ] && [ ! $$REGISTRY_PASSWORD ]; then \
				echo "REGISTRY_USERNAME and REGISTRY_PASSWORD must be populated to push the chart to an HTTPS repository"; \
				exit 1; \
			else \
				$(HELM) repo add hmc $(REGISTRY_REPO); \
				echo "Pushing $$chart to $(REGISTRY_REPO)"; \
				$(HELM) cm-push "$$chart" $(REGISTRY_REPO) --username $$REGISTRY_USERNAME --password $$REGISTRY_PASSWORD; \
			fi; \
		fi; \
	done

.PHONY: dev-collector-deploy-init-prep
dev-collector-deploy-init-prep: dev ## Prepare motel-collector helm chart values to install CRDs only
	cp -f $(TEMPLATES_DIR)/motel-collector/values.yaml dev/collector-values.yaml
	@$(YQ) eval -i '.motel.logs_endpoint = "http://$(MOTEL_STORAGE_NAME)-victoria-logs-single-server.$(MOTEL_STORAGE_NS):9428/insert/opentelemetry/v1/logs"' dev/collector-values.yaml
	@$(YQ) eval -i '.motel.metrics_endpoint = "http://vminsert-cluster.$(MOTEL_STORAGE_NS):8480/insert/0/prometheus/api/v1/write"' dev/collector-values.yaml
.PHONY: dev-collector-deploy

.PHONY: dev-collector-deploy-init
dev-collector-deploy-init: dev-collector-deploy-init-prep dev ## Deploy motel-collector helm chart to the K8s cluster specified in ~/.kube/config CRDs only
	$(HELM) upgrade -i motel-collector ./charts/motel-collector --create-namespace -n motel-collector -f dev/collector-values.yaml

.PHONY: dev-collector-deploy
dev-collector-deploy: dev-collector-deploy-init-prep dev ## Deploy motel-collector helm chart to the K8s cluster specified in ~/.kube/config CRDs only
	@$(YQ) eval -i '.["prometheus-node-exporter"].enabled = true' dev/collector-values.yaml
	@$(YQ) eval -i '.["kube-state-metrics"].enabled = true' dev/collector-values.yaml
	@$(YQ) eval -i '.["collectors"].enabled = true' dev/collector-values.yaml
	$(HELM) upgrade -i motel-collector ./charts/motel-collector --create-namespace -n motel-collector -f dev/collector-values.yaml

.PHONY: dev-storage-deploy
dev-storage-deploy: dev ## Deploy motel-storage helm chart to the K8s cluster specified in ~/.kube/config
	cp -f $(TEMPLATES_DIR)/motel-storage/values.yaml dev/storage-values.yaml
	@$(YQ) eval -i '.grafana.datasources = [{"name": "logs", "url": "http://$(MOTEL_STORAGE_NAME)-victoria-logs-single-server:9428", "type": "victoriametrics-logs-datasource" }, {"name": "metrics", "url": "http://vmselect-cluster:8481/select/0/prometheus", "type": "prometheus" } ]' dev/storage-values.yaml
	@$(YQ) eval -i '.grafana.ingress.enabled = false' dev/storage-values.yaml
	@$(YQ) eval -i '.victoriametrics.vmcluster.replicaCount = 1' dev/storage-values.yaml
	@$(YQ) eval -i '.global.storageClass = "standard"' dev/storage-values.yaml
	@$(YQ) eval -i '.["victoria-logs-single"].server.persistentVolume.storageClassName = "standard"' dev/storage-values.yaml
	$(HELM) upgrade -i $(MOTEL_STORAGE_NAME) ./charts/motel-storage --create-namespace -n $(MOTEL_STORAGE_NS) -f dev/storage-values.yaml

.PHONY: dev-ms-deploy-reg
dev-ms-deploy-reg: dev ## Deploy Mothership helm chart to the K8s cluster specified in ~/.kube/config for a remote storage cluster
	cp -f $(TEMPLATES_DIR)/motel-mothership/values.yaml dev/mothership-values.yaml
	@$(YQ) eval -i '.hmc.installTemplates = true' dev/mothership-values.yaml
	@$(YQ) eval -i '.grafana.logSources = [{"name": "$(USER)-reg", "url": "https://vmauth.$(REG_DOMAIN)/vls", "type": "victorialogs-datasource", "auth": {"username": "motel", "password": "motel"} }]' dev/mothership-values.yaml
	@$(YQ) eval -i '.promxy.config.serverGroups = [{"clusterName": "$(USER)-reg", "targets": ["vmauth.$(REG_DOMAIN):443"], "auth": {"username": "motel", "password": "motel"}}]' dev/mothership-values.yaml
	@$(YQ) eval -i '.hmc.motel.charts.child.version = "$(CHILD_VERSION)"' dev/mothership-values.yaml
	@$(YQ) eval -i '.hmc.motel.charts.regional.version = "$(REGIONAL_VERSION)"' dev/mothership-values.yaml
	@if [ "$(REGISTRY_REPO)" = "oci://127.0.0.1:$(REGISTRY_PORT)/charts" ]; then \
		$(YQ) eval -i '.hmc.motel.repo.url = "oci://$(REGISTRY_NAME):5000/charts"' dev/mothership-values.yaml; \
		$(YQ) eval -i '.hmc.motel.repo.insecure = true' dev/mothership-values.yaml; \
		$(YQ) eval -i '.hmc.motel.repo.type = "oci"' dev/mothership-values.yaml; \
	else \
		$(YQ) eval -i '.hmc.motel.repo.url = "$(REGISTRY_REPO)"' dev/mothership-values.yaml; \
	fi; \
	$(HELM) upgrade -i motel ./charts/motel-mothership -n hmc-system -f dev/mothership-values.yaml

