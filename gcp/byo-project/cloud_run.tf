
locals {
  # --- Shared Container Configuration ---
  fleet_image_tag = var.fleet_config.image_tag
  fleet_resources_limits = {
    cpu    = var.fleet_config.fleet_cpu
    memory = var.fleet_config.fleet_memory
  }
  fleet_secrets_env_vars = merge(var.fleet_config.extra_secret_env_vars, {
    FLEET_MYSQL_PASSWORD = {
      secret  = google_secret_manager_secret.database_password.secret_id
      version = "latest"
    },
    FLEET_SERVER_PRIVATE_KEY = {
      secret  = google_secret_manager_secret.private_key.secret_id
      version = "latest"
    }
  })
  fleet_env_vars = merge(var.fleet_config.extra_env_vars, {
    FLEET_LICENSE_KEY      = var.fleet_config.license_key
    FLEET_SERVER_FORCE_H2C = var.fleet_config.use_h2c
    FLEET_MYSQL_PROTOCOL   = "tcp"
    FLEET_MYSQL_ADDRESS    = "${module.mysql.private_ip_address}:3306"
    FLEET_MYSQL_USERNAME   = var.database_config.database_user
    FLEET_MYSQL_DATABASE   = var.database_config.database_name
    FLEET_REDIS_ADDRESS    = "${module.memstore.host}:${module.memstore.port}"
    FLEET_REDIS_USE_TLS    = "false"
    #FLEET_UPGRADES_ALLOW_MISSING_MIGRATIONS          = "1"
    FLEET_LOGGING_JSON                               = "true"
    FLEET_LOGGING_DEBUG                              = var.fleet_config.debug_logging
    FLEET_SERVER_TLS                                 = "false"
    FLEET_S3_SOFTWARE_INSTALLERS_BUCKET              = google_storage_bucket.software_installers.id
    FLEET_S3_SOFTWARE_INSTALLERS_ACCESS_KEY_ID       = google_storage_hmac_key.key.access_id
    FLEET_S3_SOFTWARE_INSTALLERS_SECRET_ACCESS_KEY   = google_storage_hmac_key.key.secret
    FLEET_S3_SOFTWARE_INSTALLERS_ENDPOINT_URL        = "https://storage.googleapis.com"
    FLEET_S3_SOFTWARE_INSTALLERS_FORCE_S3_PATH_STYLE = "true"
    FLEET_S3_SOFTWARE_INSTALLERS_REGION              = var.region
  })

  fleet_vpc_network_id = module.vpc.network_id
  # Use the direct construction for the subnet ID key as discussed
  fleet_vpc_subnet_id = "fleet-subnet"
}

module "fleet-service" {
  source  = "GoogleCloudPlatform/cloud-run/google//modules/v2"
  version = "0.17.2"

  # Wait for database migrations to complete before deploying the new API
  # revision. Without this, the API service and migration job update in
  # parallel — the new image tries to start before migrations finish,
  # fails health checks, and Cloud Run rolls back.
  depends_on = [terracurl_request.exec]

  service_name                  = "fleet-api"
  project_id                    = var.project_id
  location                      = var.region
  create_service_account        = false
  service_account               = google_service_account.fleet_run_sa.email
  enable_prometheus_sidecar     = false
  cloud_run_deletion_protection = false

  vpc_access = {
    network_interfaces = {
      network    = local.fleet_vpc_network_id
      subnetwork = local.fleet_vpc_subnet_id
    }
    egress = "ALL_TRAFFIC"
  }
  ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  timeout = "300s"

  service_scaling = {
    min_instance_count = var.fleet_config.min_instance_count
  }

  template_scaling = {
    min_instance_count = 0 # Google suggests using service-level minimum instance count
    max_instance_count = var.fleet_config.max_instance_count
  }

  containers = [
    {
      container_image = local.fleet_image_tag
      ports = {
        name           = var.fleet_config.use_h2c ? "h2c" : "http1"
        container_port = 8080
      }
      # container_command = ["/bin/sh"]
      # container_args = [
      #   "-c",
      #   "fleet prepare --no-prompt=true db; exec fleet serve"
      # ]

      startup_probe = {
        initial_delay_seconds = 30
        timeout_seconds       = 2
        period_seconds        = 60
        failure_threshold     = 3

        tcp_socket = {
          port = 8080
        }
      }

      liveness_probe = {
        initial_delay_seconds = 30
        timeout_seconds       = 2
        failure_threshold     = 3
        period_seconds        = 60
        http_get = {
          path         = "/healthz"
          http_headers = []
        }
      }

      resources = {
        limits = local.fleet_resources_limits
        # CPU must remain allocated outside of request processing so Fleet's
        # background cron goroutines (e.g. apple_mdm_dep_profile_assigner) can
        # run reliably. Without this, the throttled CPU between requests
        # cancels in-flight cron work mid-tick, which can silently drop DEP
        # device events. See fleetdm/fleet-terraform#242 and fleetdm/fleet#46235.
        cpu_idle = false
      }

      env_vars        = local.fleet_env_vars
      env_secret_vars = local.fleet_secrets_env_vars
    }
  ]
}

# --- Cloud Run Job (Migrations) ---
resource "google_cloud_run_v2_job" "fleet_migration_job" {

  name     = "fleet-migration"
  location = var.region
  project  = var.project_id

  template {
    template {                                                    # Double template for jobs
      service_account = google_service_account.fleet_run_sa.email # Defined in iam.tf

      # Define vpc_access block directly
      vpc_access {
        network_interfaces {
          network    = local.fleet_vpc_network_id
          subnetwork = local.fleet_vpc_subnet_id
        }
        egress = "ALL_TRAFFIC"
      }

      timeout = "3600s"

      containers {
        image = local.fleet_image_tag
        # Define resources block directly
        resources {
          limits = local.fleet_resources_limits
        }

        dynamic "env" {
          for_each = local.fleet_env_vars
          content {
            name  = env.key
            value = env.value
          }
        }
        dynamic "env" {
          for_each = local.fleet_secrets_env_vars
          content {
            name = env.key
            value_source {
              secret_key_ref {
                secret  = env.value.secret
                version = env.value.version
              }
            }
          }
        }

        command = ["fleet"]
        args    = ["prepare", "db", "--no-prompt=true"]
      }
    }
  }

  depends_on = [
    google_service_account.fleet_run_sa,
    google_secret_manager_secret_version.database_password,
  ]
}

data "google_client_config" "default" {}

resource "terracurl_request" "exec" {
  count  = var.fleet_config.exec_migration ? 1 : 0
  name   = "exec-job"
  url    = "https://run.googleapis.com/v2/${google_cloud_run_v2_job.fleet_migration_job.id}:run"
  method = "POST"
  headers = {
    Authorization = "Bearer ${data.google_client_config.default.access_token}"
    Content-Type  = "application/json",
  }
  response_codes = [200]
  // no-op destroy
  // we don't use terracurl_request data source as that will result in
  // repeated job runs on every refresh
  destroy_url            = "https://run.googleapis.com/v2/${google_cloud_run_v2_job.fleet_migration_job.id}"
  destroy_method         = "GET"
  destroy_response_codes = [200]
  destroy_headers = {
    Authorization = "Bearer ${data.google_client_config.default.access_token}"
    Content-Type  = "application/json",
  }
}

# Wait for the migration Cloud Run Job execution to actually COMPLETE (not just
# be triggered) before the new Fleet API revision deploys.
#
# terracurl_request.exec POSTs the job ":run" endpoint, which returns a
# long-running Operation immediately (fire-and-forget). So the fleet-service's
# `depends_on = [terracurl_request.exec]` only guarantees migrations were
# *started*, not *finished*. On a Fleet version bump the new API image then boots
# before migrations complete and exits(1) on pending migrations, failing its
# startup probe while traffic stays on the old revision — a stuck upgrade
# (thinkmoresecure/it#265).
#
# This resource polls the Operation returned by ":run" until it reports done,
# gating the API rollout on real migration completion. Opt-in via
# fleet_config.exec_migration_wait (default false) since it shells out to
# curl + python3 in the apply runtime.
resource "null_resource" "migration_wait" {
  count = var.fleet_config.exec_migration && var.fleet_config.exec_migration_wait ? 1 : 0

  depends_on = [terracurl_request.exec]

  # terracurl_request.exec re-runs every apply (its bearer token changes), so
  # re-run this guard every apply to wait on the freshly-launched execution.
  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      OP_RESPONSE = try(terracurl_request.exec[0].response, "")
      TOKEN       = data.google_client_config.default.access_token
    }
    command = <<-EOT
      set -euo pipefail
      op=$(printf '%s' "$${OP_RESPONSE:-}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || true)
      if [ -z "$${op:-}" ]; then
        echo "migration_wait: no operation name in migration response; nothing to wait on"
        exit 0
      fi
      echo "migration_wait: waiting for migration operation $${op} to complete"
      for i in $(seq 1 180); do
        body=$(curl -sf -H "Authorization: Bearer $${TOKEN}" "https://run.googleapis.com/v2/$${op}" || true)
        state=$(printf '%s' "$${body:-}" | python3 -c "import sys,json; d=json.load(sys.stdin); print('done' if d.get('done') and not d.get('error') else ('error' if d.get('error') else 'pending'))" 2>/dev/null || echo pending)
        if [ "$${state}" = "done" ]; then
          echo "migration_wait: migration completed successfully"
          exit 0
        fi
        if [ "$${state}" = "error" ]; then
          echo "migration_wait: migration FAILED: $${body}"
          exit 1
        fi
        sleep 5
      done
      echo "migration_wait: timed out after ~15m waiting for migration to complete"
      exit 1
    EOT
  }
}

resource "google_compute_region_network_endpoint_group" "neg" {
  name                  = "${var.prefix}-neg"
  region                = var.region
  project               = var.project_id
  network_endpoint_type = "SERVERLESS" # This type works for Cloud Run v2 services
  cloud_run {
    service = module.fleet-service.service_name
  }
  depends_on = [module.fleet-service]
}

data "google_project" "project" {
  project_id = var.project_id
}

resource "google_cloud_run_v2_service_iam_member" "allow_lb_invoker" {
  project  = var.project_id
  location = module.fleet-service.location
  name     = module.fleet-service.service_name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
