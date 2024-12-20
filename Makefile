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

COLLECTOR_VERSION=$(shell $(YQ) '.version' $(TEMPLATES_DIR)/motel-collector/Chart.yaml)
STORAGE_VERSION=$(shell $(YQ) '.version' $(TEMPLATES_DIR)/motel-storage/Chart.yaml)
USER_EMAIL=$(shell git config user.email)

STORAGE_DOMAIN = $(USER)-storage.$(MOTEL_DNS)
MOTEL_STORAGE_NAME = motel-storage
MOTEL_STORAGE_NS = motel

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

.PHONY: dev-operators-deploy
dev-operators-deploy: dev ## Deploy motel-operators helm chart to the K8s cluster specified in ~/.kube/config
	cp -f $(TEMPLATES_DIR)/motel-operators/values.yaml dev/operators-values.yaml
	$(HELM) upgrade -i motel-operators ./charts/motel-operators --create-namespace -n motel -f dev/operators-values.yaml

.PHONY: dev-collectors-deploy
dev-collectors-deploy: dev-operators-deploy dev ## Deploy motel-collector helm chart to the K8s cluster specified in ~/.kube/config
	cp -f $(TEMPLATES_DIR)/motel-collectors/values.yaml dev/collectors-values.yaml
	@$(YQ) eval -i '.motel.logs_endpoint = "http://$(MOTEL_STORAGE_NAME)-victoria-logs-single-server.$(MOTEL_STORAGE_NS):9428/insert/opentelemetry/v1/logs"' dev/collectors-values.yaml
	@$(YQ) eval -i '.motel.metrics_endpoint = "http://vminsert-cluster.$(MOTEL_STORAGE_NS):8480/insert/0/prometheus/api/v1/write"' dev/collectors-values.yaml
	$(HELM) upgrade -i motel-collectors ./charts/motel-collectors --create-namespace -n motel -f dev/collectors-values.yaml

.PHONY: dev-storage-deploy
dev-storage-deploy: dev ## Deploy motel-storage helm chart to the K8s cluster specified in ~/.kube/config
	cp -f $(TEMPLATES_DIR)/motel-storage/values.yaml dev/storage-values.yaml
	@$(YQ) eval -i '.grafana.ingress.enabled = false' dev/storage-values.yaml
	@$(YQ) eval -i '.victoriametrics.vmcluster.replicaCount = 1' dev/storage-values.yaml
	@$(YQ) eval -i '.global.storageClass = "standard"' dev/storage-values.yaml
	@$(YQ) eval -i '.["victoria-logs-single"].server.persistentVolume.storageClassName = "standard"' dev/storage-values.yaml
	$(HELM) upgrade -i $(MOTEL_STORAGE_NAME) ./charts/motel-storage --create-namespace -n $(MOTEL_STORAGE_NS) -f dev/storage-values.yaml

.PHONY: dev-ms-deploy-aws
dev-ms-deploy-aws: dev ## Deploy Mothership helm chart to the K8s cluster specified in ~/.kube/config for a remote storage cluster
	cp -f $(TEMPLATES_DIR)/motel-mothership/values.yaml dev/mothership-values.yaml
	@$(YQ) eval -i '.hmc.installTemplates = true' dev/mothership-values.yaml
	@$(YQ) eval -i '.grafana.logSources = [{"name": "$(USER)-storage", "url": "https://vmauth.$(STORAGE_DOMAIN)/vls", "type": "victoriametrics-logs-datasource", "auth": {"username": "motel", "password": "motel"} }]' dev/mothership-values.yaml
	@$(YQ) eval -i '.promxy.config.serverGroups = [{"clusterName": "$(USER)-storage", "targets": ["vmauth.$(STORAGE_DOMAIN):443"], "auth": {"username": "motel", "password": "motel"}}]' dev/mothership-values.yaml

	@$(YQ) eval -i '.hmc.motel.charts.collector.version = "$(COLLECTOR_VERSION)"' dev/mothership-values.yaml
	@$(YQ) eval -i '.hmc.motel.charts.storage.version = "$(STORAGE_VERSION)"' dev/mothership-values.yaml
	@if [ "$(REGISTRY_REPO)" = "oci://127.0.0.1:$(REGISTRY_PORT)/charts" ]; then \
		$(YQ) eval -i '.hmc.motel.repo.url = "oci://$(REGISTRY_NAME):5000/charts"' dev/mothership-values.yaml; \
		$(YQ) eval -i '.hmc.motel.repo.insecure = true' dev/mothership-values.yaml; \
		$(YQ) eval -i '.hmc.motel.repo.type = "oci"' dev/mothership-values.yaml; \
	else \
		$(YQ) eval -i '.hmc.motel.repo.url = "$(REGISTRY_REPO)"' dev/mothership-values.yaml; \
	fi; \
	$(HELM) upgrade -i motel ./charts/motel-mothership -n hmc-system -f dev/mothership-values.yaml

.PHONY: dev-storage-deploy-aws
dev-storage-deploy-aws: dev ## Deploy Regional Managed cluster using HMC
	cp -f demo/cluster/aws-storage.yaml dev/aws-storage.yaml
	@$(YQ) eval -i '.metadata.name = "$(USER)-aws-storage"' dev/aws-storage.yaml
	@$(YQ) '.spec.services[] | select(.name == "motel-storage") | .values' dev/aws-storage.yaml > dev/motel-storage-values.yaml
	@$(YQ) eval -i '.["cert-manager"].email = "$(USER_EMAIL)"' dev/motel-storage-values.yaml
	@$(YQ) eval -i '.victoriametrics.vmauth.ingress.host = "vmauth.$(STORAGE_DOMAIN)"' dev/motel-storage-values.yaml
	@$(YQ) eval -i '.grafana.ingress.host = "grafana.$(STORAGE_DOMAIN)"' dev/motel-storage-values.yaml
	@$(YQ) eval -i '.["external-dns"].enabled = true' dev/motel-storage-values.yaml
	@$(YQ) eval -i '(.spec.services[] | select(.name == "motel-storage")).values |= load_str("dev/motel-storage-values.yaml")' dev/aws-storage.yaml
	kubectl apply -f dev/aws-storage.yaml

.PHONY: dev-managed-deploy-aws
dev-managed-deploy-aws: dev ## Deploy Regional Managed cluster using HMC
	cp -f demo/cluster/aws-managed.yaml dev/aws-managed.yaml
	@$(YQ) eval -i '.metadata.name = "$(USER)-aws-managed"' dev/aws-managed.yaml
	@$(YQ) '.spec.services[] | select(.name == "motel-collectors") | .values' dev/aws-managed.yaml > dev/motel-managed-values.yaml
	@$(YQ) eval -i '.opencost.prometheus.external.url = "https://vmauth.$(STORAGE_DOMAIN)/vm/select/0/prometheus"' dev/motel-managed-values.yaml
	@$(YQ) eval -i '.motel.logs_endpoint = "https://vmauth.$(STORAGE_DOMAIN)/vls/insert/opentelemetry/v1/logs"' dev/motel-managed-values.yaml
	@$(YQ) eval -i '.motel.metrics_endpoint = "https://vmauth.$(STORAGE_DOMAIN)/vm/insert/0/prometheus/api/v1/write"' dev/motel-managed-values.yaml
	@$(YQ) eval -i '(.spec.services[] | select(.name == "motel-collectors")).values |= load_str("dev/motel-managed-values.yaml")' dev/aws-managed.yaml
	kubectl apply -f dev/aws-managed.yaml
