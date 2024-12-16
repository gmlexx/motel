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
		else \
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
		fi; \
	done

.PHONY: dev-ms-deploy
dev-ms-deploy: dev ## Deploy Mothership helm chart to the K8s cluster specified in ~/.kube/config.
	cp -f $(TEMPLATES_DIR)/motel-mothership/values.yaml dev/mothership-values.yaml
	@$(YQ) eval -i '.hmc.installTemplates = true' dev/mothership-values.yaml
	@$(YQ) eval -i '.grafana.logSources = [{"name": "$(USER)-reg", "url": "https://vmauth.$(USER)-reg.$(MOTEL_DNS)/vls", "type": "victorialogs-datasource", "auth": {"username": "motel", "password": "motel"} }]' dev/mothership-values.yaml
	@$(YQ) eval -i '.promxy.config.serverGroups = [{"clusterName": "$(USER)-reg", "targets": ["vmauth.$(USER)-reg.$(MOTEL_DNS):443"], "auth": {"username": "motel", "password": "motel"}}]' dev/mothership-values.yaml
	@$(YQ) eval -i '.hmc.motel.charts.child.version = "$(CHILD_VERSION)"' dev/mothership-values.yaml
	@$(YQ) eval -i '.hmc.motel.charts.regional.version = "$(REGIONAL_VERSION)"' dev/mothership-values.yaml
	@if [ "$(REGISTRY_REPO)" = "oci://127.0.0.1:$(REGISTRY_PORT)/charts" ]; then \
		$(YQ) eval -i '.hmc.motel.repo.url = "oci://$(REGISTRY_NAME):5000/charts"' dev/mothership-values.yaml; \
	else \
		$(YQ) eval -i '.hmc.motel.repo.url = "$(REGISTRY_REPO)"' dev/mothership-values.yaml; \
	fi; \

