.PHONY: bootstrap-init mgmt-deploy mgmt-destroy build-api-image push-api-image tre-deploy tre-destroy letsencrypt
.DEFAULT_GOAL := help

SHELL:=/bin/bash
MAKEFILE_FULLPATH := $(abspath $(lastword $(MAKEFILE_LIST)))
MAKEFILE_DIR := $(dir $(MAKEFILE_FULLPATH))
IMAGE_NAME_PREFIX?="microsoft/azuretre"
ACR_DOMAIN_SUFFIX?=`az cloud show --query suffixes.acrLoginServerEndpoint --output tsv`
ACR_NAME?=`echo "$${ACR_NAME}" | tr A-Z a-z`
ACR_FQDN?="${ACR_NAME}${ACR_DOMAIN_SUFFIX}"
FULL_IMAGE_NAME_PREFIX:=${ACR_FQDN}/${IMAGE_NAME_PREFIX}
LINTER_REGEX_INCLUDE?=all # regular expression used to specify which files to include in local linting (defaults to "all")
E2E_TESTS_NUMBER_PROCESSES_DEFAULT=4  # can be overridden in e2e_tests/.env

target_title = @echo -e "\n\e[34m»»» 🧩 \e[96m$(1)\e[0m..."

# Command: all
# Description: Provision all the application resources from beginning to end
all: bootstrap mgmt-deploy images tre-deploy ## 🚀 Provision all the application resources from beginning to end

# Command: tre-deploy
# Description: Provision TRE using existing images
tre-deploy: deploy-core build-and-deploy-ui firewall-install db-migrate show-core-output ## 🚀 Provision TRE using existing images

# Command: images
# Description: Build and push all images
images: build-and-push-api build-and-push-resource-processor build-and-push-airlock-processor ## 📦 Build and push all images

# Command: images
# Description: Build and push API image
build-and-push-api: build-api-image push-api-image

# Command: images
# Description: Build and push Resource Processor image
build-and-push-resource-processor: build-resource-processor-vm-porter-image push-resource-processor-vm-porter-image

# Command: images
# Description: Build and push Airlock Processor image
build-and-push-airlock-processor: build-airlock-processor push-airlock-processor

help: ## 💬 This help message :)
	@grep -E '[a-zA-Z_-]+:.*?## .*$$' $(firstword $(MAKEFILE_LIST)) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-25s\033[0m %s\n", $$1, $$2}'

# to move your environment from the single 'core' deployment (which includes the firewall)
# toward the shared services model, where it is split out - run the following make target before a tre-deploy
# This will remove + import the resource state into a shared service
migrate-firewall-state: prepare-tf-state

# Command: bootstrap
# Description: Bootstrap Terraform
bootstrap:
	$(call target_title, "Bootstrap Terraform") \
	&& . ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh nodocker,env \
	&& cd ${MAKEFILE_DIR}/devops/terraform && ./bootstrap.sh

# Command: mgmt-deploy
# Description: Deploy management infrastructure. This will create the management resource group with the necessary resources such as Azure Container Registry, Storage Account for the tfstate and KV for Encryption Keys if enabled.
mgmt-deploy:
	$(call target_title, "Deploying management infrastructure") \
	&& . ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh nodocker,env \
	&& cd ${MAKEFILE_DIR}/devops/terraform && ./deploy.sh

# Command: mgmt-destroy
# Description: Destroy management infrastructure. This will destroy the management resource group with the resources in it.
mgmt-destroy:
	$(call target_title, "Destroying management infrastructure") \
	. ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh nodocker,env \
	&& cd ${MAKEFILE_DIR}/devops/terraform && ./destroy.sh

# A recipe for building images. Parameters:
# 1. Image name suffix
# 2. Version file path
# 3. Docker file path
# 4. Docker context path
# Example: $(call build_image,"api","./api_app/_version.py","api_app/Dockerfile","./api_app/")
# The CI_CACHE_ACR_NAME is an optional container registry used for caching in addition to what's in ACR_NAME
define build_image
$(call target_title, "Building $(1) Image") \
&& . ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh env \
&& . ${MAKEFILE_DIR}/devops/scripts/set_docker_sock_permission.sh \
&& source <(grep = $(2) | sed 's/ *= */=/g') \
&& az acr login -n ${ACR_NAME} \
&& if [ -n "$${CI_CACHE_ACR_NAME:-}" ]; then \
	az acr login -n $${CI_CACHE_ACR_NAME}; \
	ci_cache="--cache-from $${CI_CACHE_ACR_NAME}${ACR_DOMAIN_SUFFIX}/${IMAGE_NAME_PREFIX}/$(1):$${__version__}"; fi \
&& docker build -t ${FULL_IMAGE_NAME_PREFIX}/$(1):$${__version__} --build-arg BUILDKIT_INLINE_CACHE=1 \
	--cache-from ${FULL_IMAGE_NAME_PREFIX}/$(1):$${__version__} $${ci_cache:-} -f $(3) $(4)
endef

# Command: build-api-image
# Description: Build API image
build-api-image:
	$(call build_image,"api","${MAKEFILE_DIR}/api_app/_version.py","${MAKEFILE_DIR}/api_app/Dockerfile","${MAKEFILE_DIR}/api_app/")

# Command: build-resource-processor-vm-porter-image
# Description: Build Resource Processor VM Porter image
build-resource-processor-vm-porter-image:
	$(call build_image,"resource-processor-vm-porter","${MAKEFILE_DIR}/resource_processor/_version.py","${MAKEFILE_DIR}/resource_processor/vmss_porter/Dockerfile","${MAKEFILE_DIR}/resource_processor/")

# Command: build-airlock-processor
# Description: Build Airlock Processor image
build-airlock-processor:
	$(call build_image,"airlock-processor","${MAKEFILE_DIR}/airlock_processor/_version.py","${MAKEFILE_DIR}/airlock_processor/Dockerfile","${MAKEFILE_DIR}/airlock_processor/")

# A recipe for pushing images. Parameters:
# 1. Image name suffix
# 2. Version file path
# Example: $(call push_image,"api","./api_app/_version.py")
define push_image
$(call target_title, "Pushing $(1) Image") \
&& . ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh env \
&& . ${MAKEFILE_DIR}/devops/scripts/set_docker_sock_permission.sh \
&& source <(grep = $(2) | sed 's/ *= */=/g') \
&& az acr login -n ${ACR_NAME} \
&& docker push "${FULL_IMAGE_NAME_PREFIX}/$(1):$${__version__}"
endef

# Command: push-api-image
# Description: Push API image to ACR
push-api-image:
	$(call push_image,"api","${MAKEFILE_DIR}/api_app/_version.py")

# Command: push-resource-processor-vm-porter-image
# Description: Push Resource Processor VM Porter image to ACR
push-resource-processor-vm-porter-image:
	$(call push_image,"resource-processor-vm-porter","${MAKEFILE_DIR}/resource_processor/_version.py")

# Command: push-airlock-processor
# Description: Push Airlock Processor image to ACR
push-airlock-processor:
	$(call push_image,"airlock-processor","${MAKEFILE_DIR}/airlock_processor/_version.py")

# Command: prepare-tf-state
# Description: Prepare terraform state for migration
# # These targets are for a graceful migration of Firewall
# # from terraform state in Core to a Shared Service.
# # See https://github.com/microsoft/AzureTRE/issues/1177
prepare-tf-state:
	$(call target_title, "Preparing terraform state") \
	&& . ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh nodocker,env \
	&& pushd ${MAKEFILE_DIR}/core/terraform > /dev/null && ../../shared_services/firewall/terraform/remove_state.sh && popd > /dev/null \
	&& pushd ${MAKEFILE_DIR}/templates/shared_services/firewall/terraform > /dev/null && ./import_state.sh && popd > /dev/null
# / End migration targets

# Command: deploy-core
# Description: Deploy the core infrastructure of TRE.
deploy-core: tre-start
	$(call target_title, "Deploying TRE") \
	&& . ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh nodocker,env \
	&& rm -fr ~/.config/tre/environment.json \
	&& if [[ "$${TF_LOG}" == "DEBUG" ]]; \
		then echo "TF DEBUG set - output supressed - see tflogs container for log file" && cd ${MAKEFILE_DIR}/core/terraform/ \
			&& ./deploy.sh 1>/dev/null 2>/dev/null; \
		else cd ${MAKEFILE_DIR}/core/terraform/ && ./deploy.sh; fi;

# Command: letsencrypt
# Description: Request LetsEncrypt SSL certificate
letsencrypt:
	$(call target_title, "Requesting LetsEncrypt SSL certificate") \
	&& . ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh nodocker,certbot,env \
	&& pushd ${MAKEFILE_DIR}/core/terraform/ > /dev/null && . ./outputs.sh && popd > /dev/null \
	&& . ${MAKEFILE_DIR}/devops/scripts/load_env.sh ${MAKEFILE_DIR}/core/private.env \
	&& ${MAKEFILE_DIR}/core/terraform/scripts/letsencrypt.sh

# Command: tre-start
# Description: Start the TRE Service. This will allocate the Azure Firewall settings with a public IP and start the Azure Application Gateway service, starting billing of both services.
tre-start: ## ⏩ Start the TRE Service
	$(call target_title, "Starting TRE") \
	&& . ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh env \
	&& ${MAKEFILE_DIR}/devops/scripts/control_tre.sh start

# Command: tre-stop
# Description: Stop the TRE Service. This will deallocate the Azure Firewall public IP and stop the Azure Application Gateway service, stopping billing of both services.
tre-stop: ## ⛔ Stop the TRE Service
	$(call target_title, "Stopping TRE") \
	&& . ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh env \
	&& ${MAKEFILE_DIR}/devops/scripts/control_tre.sh stop

# Command: tre-destroy
# Description: Destroy the TRE Service. This will destroy all the resources of the TRE service, including the Azure Firewall and Application Gateway.
tre-destroy: ## 🧨 Destroy the TRE Service
	$(call target_title, "Destroying TRE") \
	&& . ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh nodocker,env \
	&& . ${MAKEFILE_DIR}/devops/scripts/destroy_env_no_terraform.sh

# Command: terraform-deploy
# Description: Deploy the Terraform resources in the specified directory.
terraform-deploy:
	$(call target_title, "Deploying ${DIR} with Terraform") \
	&& . ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh env \
	&& . ${MAKEFILE_DIR}/devops/scripts/load_and_validate_env.sh \
	&& . ${MAKEFILE_DIR}/devops/scripts/load_env.sh ${DIR}/.env \
	&& cd ${DIR}/terraform/ && ./deploy.sh

# Command: terraform-upgrade
# Description: Upgrade the Terraform resources in the specified directory.
terraform-upgrade:
	$(call target_title, "Upgrading ${DIR} with Terraform") \
	&& . ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh env \
	&& . ${MAKEFILE_DIR}/devops/scripts/load_and_validate_env.sh \
	&& . ${MAKEFILE_DIR}/devops/scripts/load_env.sh ${DIR}/.env \
	&& cd ${DIR}/terraform/ && ./upgrade.sh

# Command: terraform-import
# Description: Import the Terraform resources in the specified directory.
terraform-import:
	$(call target_title, "Importing ${DIR} with Terraform") \
	&& . ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh env \
	&& cd ${DIR}/terraform/ && ./import.sh

# Command: terraform-destroy
# Description: Destroy the Terraform resources in the specified directory.
terraform-destroy:
	$(call target_title, "Destroying ${DIR} Service") \
	&& . ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh env \
	&& . ${MAKEFILE_DIR}/devops/scripts/load_and_validate_env.sh \
	&& . ${MAKEFILE_DIR}/devops/scripts/load_env.sh ${DIR}/.env \
	&& cd ${DIR}/terraform/ && ./destroy.sh

# Command: lint
# Description: Lint files. This will validate all files, not only the changed ones as the CI version does.
lint: ## 🧹 Lint all files
	$(call target_title, "Linting")
	@terraform fmt -check -recursive -diff
	@# LOG_LEVEL=NOTICE reduces noise but it might also seem like the process is stuck - it's not...
	@docker run --name superlinter --pull=always --rm \
		-e RUN_LOCAL=true \
		-e LOG_LEVEL=NOTICE \
		-e VALIDATE_MARKDOWN=true \
		-e VALIDATE_PYTHON_FLAKE8=true \
		-e VALIDATE_YAML=true \
		-e VALIDATE_TERRAFORM_TFLINT=true \
		-e VALIDATE_JAVA=true \
		-e JAVA_FILE_NAME=checkstyle.xml \
		-e VALIDATE_BASH=true \
		-e VALIDATE_BASH_EXEC=true \
		-e VALIDATE_GITHUB_ACTIONS=true \
		-e VALIDATE_DOCKERFILE_HADOLINT=true \
		-e VALIDATE_TSX=true \
    -e VALIDATE_TYPESCRIPT_ES=true \
		-e FILTER_REGEX_INCLUDE=${LINTER_REGEX_INCLUDE} \
		-v $${LOCAL_WORKSPACE_FOLDER}:/tmp/lint \
		github/super-linter:slim-v5.0.0

# Command: lint-docs
# Description: Lint documentation files
lint-docs:
	LINTER_REGEX_INCLUDE='./docs/.*\|./mkdocs.yml' $(MAKE) lint

# Command: bundle-build
# Description: Build the bundle with Porter.
# check-params is called at the end since it needs the bundle image,
# so we build it first and then run the check.
# Arguments: DIR - the directory of the bundle
# Example: make bundle-build DIR="./templates/workspaces/base"
bundle-build:
	$(call target_title, "Building ${DIR} bundle with Porter") \
	&& . ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh porter,env \
	&& . ${MAKEFILE_DIR}/devops/scripts/set_docker_sock_permission.sh \
	&& cd ${DIR} \
	&& if [ -d terraform ]; then terraform -chdir=terraform init -backend=false; terraform -chdir=terraform validate; fi \
	&& FULL_IMAGE_NAME_PREFIX=${FULL_IMAGE_NAME_PREFIX} IMAGE_NAME_PREFIX=${IMAGE_NAME_PREFIX} \
		${MAKEFILE_DIR}/devops/scripts/bundle_runtime_image_build.sh \
	&& ${MAKEFILE_DIR}/devops/scripts/porter_build_bundle.sh \
	  $(MAKE) bundle-check-params

# Command: bundle-install
# Description: Install the bundle with Porter.
# Arguments: DIR - the directory of the bundle
# Example: make bundle-install DIR="./templates/workspaces/base"
bundle-install: bundle-check-params
	$(call target_title, "Deploying ${DIR} with Porter") \
	&& . ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh porter,env \
	&& . ${MAKEFILE_DIR}/devops/scripts/load_and_validate_env.sh \
	&& cd ${DIR} \
	&& . ${MAKEFILE_DIR}/devops/scripts/load_env.sh .env \
	&& porter parameters apply parameters.json \
	&& porter credentials apply ${MAKEFILE_DIR}/resource_processor/vmss_porter/aad_auth_local_debugging.json \
	&& porter credentials apply ${MAKEFILE_DIR}/resource_processor/vmss_porter/arm_auth_local_debugging.json \
	&& . ${MAKEFILE_DIR}/devops/scripts/porter_local_env.sh \
	&& porter install --autobuild-disabled --parameter-set $$(yq ".name" porter.yaml) \
		--credential-set arm_auth \
		--credential-set aad_auth \
		--debug

# Command: bundle-check-params
# Description: Validates that the parameters file is synced with the bundle.
# The file is used when installing the bundle from a local machine.
# We remove arm_use_msi on both sides since it shouldn't take effect locally anyway.
# Arguments: DIR - the directory of the bundle
# Example: make bundle-check-params DIR="./templates/workspaces/base"
bundle-check-params:
	$(call target_title, "Checking bundle parameters in ${DIR}") \
	&& . ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh nodocker,porter \
	&& cd ${DIR} \
	&& if [ ! -f "parameters.json" ]; then echo "Error - please create a parameters.json file."; exit 1; fi \
	&& if [ "$$(jq -r '.name' parameters.json)" != "$$(yq eval '.name' porter.yaml)" ]; then echo "Error - ParameterSet name isn't equal to bundle's name."; exit 1; fi \
	&& if ! porter explain --autobuild-disabled > /dev/null; then echo "Error - porter explain issue!"; exit 1; fi \
	&& comm_output=$$(set -o pipefail && comm -3 --output-delimiter=: <(porter explain --autobuild-disabled -ojson | jq -r '.parameters[].name | select (. != "arm_use_msi")' | sort) <(jq -r '.parameters[].name | select(. != "arm_use_msi")' parameters.json | sort)) \
	&& if [ ! -z "$${comm_output}" ]; \
		then echo -e "*** Add to params ***:*** Remove from params ***\n$$comm_output" | column -t -s ":"; exit 1; \
		else echo "parameters.json file up-to-date."; fi

# Command: bundle-uninstall
# Description: Uninstall the bundle with Porter.
# Arguments: DIR - the directory of the bundle
# Example: make bundle-uninstall DIR="./templates/workspaces/base"
bundle-uninstall:
	$(call target_title, "Uninstalling ${DIR} with Porter") \
	&& . ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh porter,env \
	&& . ${MAKEFILE_DIR}/devops/scripts/load_and_validate_env.sh \
	&& cd ${DIR} \
	&& . ${MAKEFILE_DIR}/devops/scripts/load_env.sh .env \
	&& porter parameters apply parameters.json \
	&& porter credentials apply ${MAKEFILE_DIR}/resource_processor/vmss_porter/aad_auth_local_debugging.json \
	&& porter credentials apply ${MAKEFILE_DIR}/resource_processor/vmss_porter/arm_auth_local_debugging.json \
	&& porter uninstall --autobuild-disabled --parameter-set $$(yq ".name" porter.yaml) \
		--credential-set arm_auth \
		--credential-set aad_auth \
		--debug

# Command: bundle-custom-action
# Description: Perform a custom action on the bundle with Porter.
# Arguments: 1. DIR - the directory of the bundle 2. ACTION - the action to perform
# Example: make bundle-custom-action DIR="./templates/workspaces/base" ACTION="action"
bundle-custom-action:
 	$(call target_title, "Performing:${ACTION} ${DIR} with Porter") \
 	&& . ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh porter,env \
	&& . ${MAKEFILE_DIR}/devops/scripts/load_and_validate_env.sh \
	&& cd ${DIR}
	&& . ${MAKEFILE_DIR}/devops/scripts/load_env.sh .env \
	&& porter parameters apply parameters.json \
	&& porter credentials apply ${MAKEFILE_DIR}/resource_processor/vmss_porter/aad_auth_local_debugging.json \
	&& porter credentials apply ${MAKEFILE_DIR}/resource_processor/vmss_porter/arm_auth_local_debugging.json \
 	&& porter invoke --autobuild-disabled --action ${ACTION} --parameter-set $$(yq ".name" porter.yaml) \
		--credential-set arm_auth \
		--credential-set aad_auth \
		--debug

# Command: bundle-publish
# Description: Publish the bundle with Porter to ACR.
# Arguments: DIR - the directory of the bundle
# Example: make bundle-publish DIR="./templates/workspaces/base"
bundle-publish:
	$(call target_title, "Publishing ${DIR} bundle with Porter") \
	&& . ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh porter,env \
	&& . ${MAKEFILE_DIR}/devops/scripts/set_docker_sock_permission.sh \
	&& az acr login --name ${ACR_NAME}	\
	&& cd ${DIR} \
	&& FULL_IMAGE_NAME_PREFIX=${FULL_IMAGE_NAME_PREFIX} \
		${MAKEFILE_DIR}/devops/scripts/bundle_runtime_image_push.sh \
	&& porter publish --registry "${ACR_FQDN}" --force

# Command: bundle-register
# Description: Register the bundle with the TRE API.
# Arguments: DIR - the directory of the bundle
# Example: make bundle-register DIR="./templates/workspaces/base"
bundle-register:
	$(call target_title, "Registering ${DIR} bundle") \
	&& . ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh porter,env \
	&& . ${MAKEFILE_DIR}/devops/scripts/set_docker_sock_permission.sh \
	&& az acr login --name ${ACR_NAME}	\
	&& ${MAKEFILE_DIR}/devops/scripts/ensure_cli_signed_in.sh $${TRE_URL} \
	&& cd ${DIR} \
	&& ${MAKEFILE_DIR}/devops/scripts/register_bundle_with_api.sh --acr-name "${ACR_NAME}" --bundle-type "$${BUNDLE_TYPE}" \
		--current --verify \
		--workspace-service-name "$${WORKSPACE_SERVICE_NAME}"

# Command: workspace_bundle
# Description: Build, publish and register a workspace bundle.
# Arguments: BUNDLE - the name of the bundle
# Example: make workspace_bundle BUNDLE=base
# Note: the BUNDLE variable is used to specify the name of the bundle. This should be equivalent to the name of the directory of the template in the templates/workspaces directory.
workspace_bundle:
	$(MAKE) bundle-build bundle-publish bundle-register \
	DIR="${MAKEFILE_DIR}/templates/workspaces/${BUNDLE}" BUNDLE_TYPE=workspace

# Command: workspace_service_bundle
# Description: Build, publish and register a workspace service bundle.
# Arguments: BUNDLE - the name of the bundle
# Example: make workspace_service_bundle BUNDLE=guacamole
# Note: the BUNDLE variable is used to specify the name of the bundle. This should be equivalent to the name of the directory of the template in the templates/workspace_services directory.
workspace_service_bundle:
	$(MAKE) bundle-build bundle-publish bundle-register \
	DIR="${MAKEFILE_DIR}/templates/workspace_services/${BUNDLE}" BUNDLE_TYPE=workspace_service

# Command: shared_service_bundle
# Description: Build, publish and register a shared service bundle.
# Arguments: BUNDLE - the name of the bundle
# Example: make shared_service_bundle BUNDLE=gitea
# Note: the BUNDLE variable is used to specify the name of the bundle. This should be equivalent to the name of the directory of the template in the templates/shared_services directory.
shared_service_bundle:
	$(MAKE) bundle-build bundle-publish bundle-register \
	DIR="${MAKEFILE_DIR}/templates/shared_services/${BUNDLE}" BUNDLE_TYPE=shared_service

# Command: user_resource_bundle
# Description: Build, publish and register a user resource bundle.
# Arguments: 1. WORKSPACE_SERVICE - the name of the workspace service 2. BUNDLE - the name of the bundle
# Example: make user_resource_bundle WORKSPACE_SERVICE=guacamole BUNDLE=guacamole-azure-windowsvm
# Note: the WORKSPACE_SERVICE variable is used to specify the name of the workspace service. This should be equivalent to the name of the directory of the template in the templates/workspace_services directory.
# And the BUNDLE variable is used to specify the name of the bundle. This should be equivalent to the name of the directory of the template in the templates/workspace_services/${WORKSPACE_SERVICE}/user_resources directory.
user_resource_bundle:
	$(MAKE) bundle-build bundle-publish bundle-register \
	DIR="${MAKEFILE_DIR}/templates/workspace_services/${WORKSPACE_SERVICE}/user_resources/${BUNDLE}" BUNDLE_TYPE=user_resource WORKSPACE_SERVICE_NAME=tre-service-${WORKSPACE_SERVICE}

# Command: bundle-publish-register-all
# Description: Publish and register all bundles.
bundle-publish-register-all:
	${MAKEFILE_DIR}/devops/scripts/publish_and_register_all_bundles.sh

# Command: deploy-shared-service
# Description: Deploy a shared service.
# Arguments: DIR - the directory of the shared service
# Example: make deploy-shared-service DIR="./templates/shared_services/firewall/"
deploy-shared-service:
	$(call target_title, "Deploying ${DIR} shared service") \
	&& . ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh porter,env \
	&& ${MAKEFILE_DIR}/devops/scripts/ensure_cli_signed_in.sh $${TRE_URL} \
	&& cd ${DIR} \
	&& ${MAKEFILE_DIR}/devops/scripts/deploy_shared_service.sh $${PROPS}

# Command: firewall-install
# Description: Build, publish and register the firewall shared service. And then deploy the firewall shared service.
firewall-install:
	$(MAKE) bundle-build bundle-publish bundle-register deploy-shared-service \
	DIR=${MAKEFILE_DIR}/templates/shared_services/firewall/ BUNDLE_TYPE=shared_service

# Command: static-web-upload
# Description: Upload the static website to the storage account
static-web-upload:
	$(call target_title, "Uploading to static website") \
	&& . ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh nodocker,env \
	&& pushd ${MAKEFILE_DIR}/core/terraform/ > /dev/null && . ./outputs.sh && popd > /dev/null \
	&& . ${MAKEFILE_DIR}/devops/scripts/load_env.sh ${MAKEFILE_DIR}/core/private.env \
	&& ${MAKEFILE_DIR}/devops/scripts/upload_static_web.sh

# Command: build-and-deploy-ui
# Description: Build and deploy the UI
build-and-deploy-ui:
	$(call target_title, "Build and deploy UI") \
	&& . ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh nodocker,env \
	&& pushd ${MAKEFILE_DIR}/core/terraform/ > /dev/null && . ./outputs.sh && popd > /dev/null \
	&& . ${MAKEFILE_DIR}/devops/scripts/load_env.sh ${MAKEFILE_DIR}/core/private.env \
	&& if [ "$${DEPLOY_UI}" != "false" ]; then ${MAKEFILE_DIR}/devops/scripts/build_deploy_ui.sh; else echo "UI Deploy skipped as DEPLOY_UI is false"; fi \

# Command: prepare-for-e2e
# Description: Prepare for E2E tests by building and registering the necessary bundles such as base workspace, guacamole, gitea, guacamole-azure-windowsvm, guacamole-azure-linuxvm
prepare-for-e2e:
	$(MAKE) workspace_bundle BUNDLE=base
	$(MAKE) workspace_service_bundle BUNDLE=guacamole
	$(MAKE) shared_service_bundle BUNDLE=gitea
	$(MAKE) user_resource_bundle WORKSPACE_SERVICE=guacamole BUNDLE=guacamole-azure-windowsvm
	$(MAKE) user_resource_bundle WORKSPACE_SERVICE=guacamole BUNDLE=guacamole-azure-linuxvm

# Command: test-e2e-smoke
# Description: Run E2E smoke tests
test-e2e-smoke:	## 🧪 Run E2E smoke tests
	$(call target_title, "Running E2E smoke tests") && \
	$(MAKE) test-e2e-custom SELECTOR=smoke

# Command: test-e2e-extended
# Description: Run E2E extended tests
test-e2e-extended: ## 🧪 Run E2E extended tests
	$(call target_title, "Running E2E extended tests") && \
	$(MAKE) test-e2e-custom SELECTOR=extended

# Command: test-e2e-extended-aad
# Description: Run E2E extended AAD tests
test-e2e-extended-aad: ## 🧪 Run E2E extended AAD tests
	$(call target_title, "Running E2E extended AAD tests") && \
	$(MAKE) test-e2e-custom SELECTOR=extended_aad

# Command: test-e2e-shared-services
# Description: Run E2E shared service tests
test-e2e-shared-services: ## 🧪 Run E2E shared service tests
	$(call target_title, "Running E2E shared service tests") && \
	$(MAKE) test-e2e-custom SELECTOR=shared_services

# Command: test-e2e-custom
# Description: Run E2E tests with custom selector
# Arguments: SELECTOR - the selector to run the tests with
# Example: make test-e2e-custom SELECTOR=smoke
test-e2e-custom: ## 🧪 Run E2E tests with custom selector (SELECTOR=)
	$(call target_title, "Running E2E tests with custom selector ${SELECTOR}") \
	&& . ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh env,auth \
	&& . ${MAKEFILE_DIR}/devops/scripts/load_env.sh ${MAKEFILE_DIR}/e2e_tests/.env \
	&& cd ${MAKEFILE_DIR}/e2e_tests \
	&& \
		if [[ -n "$${E2E_TESTS_NUMBER_PROCESSES}" && "$${E2E_TESTS_NUMBER_PROCESSES}" -ne 1 ]]; then \
			python -m pytest -n "$${E2E_TESTS_NUMBER_PROCESSES}" -m "${SELECTOR}" --verify $${IS_API_SECURED:-true} --junit-xml "pytest_e2e_$${SELECTOR// /_}.xml"; \
		elif [[ "$${E2E_TESTS_NUMBER_PROCESSES}" -eq 1 ]]; then \
			python -m pytest -m "${SELECTOR}" --verify $${IS_API_SECURED:-true} --junit-xml "pytest_e2e_$${SELECTOR// /_}.xml"; \
		else \
			python -m pytest -n "${E2E_TESTS_NUMBER_PROCESSES_DEFAULT}" -m "${SELECTOR}" --verify $${IS_API_SECURED:-true} --junit-xml "pytest_e2e_$${SELECTOR// /_}.xml"; fi

# Command: setup-local-debugging
# Description: Setup the ability to debug the API and Resource Processor
setup-local-debugging: ## 🛠️ Setup local debugging
	$(call target_title,"Setting up the ability to debug the API and Resource Processor") \
	&& . ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh nodocker,env \
	&& pushd ${MAKEFILE_DIR}/core/terraform/ > /dev/null && . ./outputs.sh && popd > /dev/null \
	&& . ${MAKEFILE_DIR}/devops/scripts/load_env.sh ${MAKEFILE_DIR}/core/private.env \
	&& . ${MAKEFILE_DIR}/devops/scripts/setup_local_debugging.sh

# Command: auth
# Description: Create the necessary Azure Active Directory assets for TRE.
auth: ## 🔐 Create the necessary Azure Active Directory assets
	$(call target_title,"Setting up Azure Active Directory") \
	&& . ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh nodocker,env \
	&& ${MAKEFILE_DIR}/devops/scripts/create_aad_assets.sh

# Command: show-core-output
# Description: Display TRE core output
show-core-output:
	$(call target_title,"Display TRE core output") \
	&& . ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh env \
	&& pushd ${MAKEFILE_DIR}/core/terraform/ > /dev/null && terraform show && popd > /dev/null

# Command: api-healthcheck
# Description: Check the API health
api-healthcheck:
	$(call target_title,"Checking API Health") \
	&& . ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh nodocker,env \
	&& . ${MAKEFILE_DIR}/devops/scripts/load_env.sh ${MAKEFILE_DIR}/core/private.env \
	&& ${MAKEFILE_DIR}/devops/scripts/api_healthcheck.sh

# Command: db-migrate
# Description: Run database migrations
db-migrate: api-healthcheck ## 🗄️ Run database migrations
	$(call target_title,"Migrating Cosmos Data") \
	&& . ${MAKEFILE_DIR}/devops/scripts/check_dependencies.sh nodocker,env \
	&& pushd ${MAKEFILE_DIR}/core/terraform/ > /dev/null && . ./outputs.sh && popd > /dev/null \
	&& . ${MAKEFILE_DIR}/devops/scripts/load_env.sh ${MAKEFILE_DIR}/core/private.env \
	&& . ${MAKEFILE_DIR}/devops/scripts/get_access_token.sh \
	&& . ${MAKEFILE_DIR}/devops/scripts/migrate_state_store.sh --tre_url $${TRE_URL} --insecure
