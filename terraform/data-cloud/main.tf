/**
 * Copyright 2024 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

locals {
  dimensions = {
    "small" = {
      slots   = 100
      ram     = 16
      edition = "BASIC"
    }
    "large" = {
      slots   = 200
      ram     = 32
      edition = "ENTERPRISE"
    }
  }
}

resource "random_string" "random" {
  length  = 4
  special = false
  upper   = false
}

resource "google_folder" "data_cloud" {
  display_name = "Pasture Data Cloud"
  parent       = data.google_active_folder.sandbox.name

  depends_on = [
    google_folder_iam_member.folder_admin,
    google_folder_iam_member.project_creator,
    google_folder_iam_member.owner,
  ]
}

module "projects" {
  source = "github.com/GoogleCloudPlatform/cloud-foundation-fabric//blueprints/factories/project-factory?ref=v29.0.0"

  data_defaults = {
    billing_account = var.billing_account.id
    parent          = google_folder.data_cloud.id
  }

  data_merges = {
    labels = {
        source    = "pastures"
        seed      = "data-cloud"
        blueprint = "data-foundation"
    }
    services = [
      "logging.googleapis.com",
      "monitoring.googleapis.com",
      "stackdriver.googleapis.com",
      "iam.googleapis.com",
      "serviceusage.googleapis.com",
      "servicemanagement.googleapis.com",
      "cloudapis.googleapis.com",
      "cloudresourcemanager.googleapis.com",
      "cloudidentity.googleapis.com"
    ]
  }

  data_overrides = {
    prefix = "pasture-${var.prefix}-${random_string.random.result}"
  }

  factory_data_path = "data/projects"
}

resource "google_bigquery_reservation" "reservation" {
  count   = var.internal_env == "true" ? 0 : 1
  project = module.projects.projects["cmn"].id

  name              = "pastures-data-cloud"
  location          = var.locations.bq
  slot_capacity     = local.dimensions[var.pasture_size].slots
  edition           = "ENTERPRISE_PLUS"
  ignore_idle_slots = false
  concurrency       = 0
  autoscale {
    max_slots = 400
  }
}

resource "google_bigquery_reservation_assignment" "assignment" {
  count   = var.internal_env == "true" ? 0 : 1
  project = module.projects.projects["cmn"].id

  assignee    = google_folder.data_cloud.id
  job_type    = "QUERY"
  reservation = google_bigquery_reservation.reservation[0].id
}

resource "google_bigquery_bi_reservation" "bi_reservation" {
  count   = var.internal_env == "true" ? 0 : 1
  project = module.projects.projects["exp"].id

  location = var.locations.bq
  size     = local.dimensions[var.pasture_size].ram * pow(1024, 3)
}

module "datafusion" {
  source     = "github.com/GoogleCloudPlatform/cloud-foundation-fabric//modules/datafusion?ref=v29.0.0"
  project_id = module.projects.projects["lod"].id
  name       = "pasture-datafusion"
  region     = var.region
  type       = local.dimensions[var.pasture_size].edition

  network              = data.google_compute_networks.load.networks[0]
  firewall_create      = true
  ip_allocation_create = true
  private_instance     = true
  network_peering      = true

  enable_stackdriver_logging    = true
  enable_stackdriver_monitoring = true
}

module "data-platform" {
  source              = "github.com/GoogleCloudPlatform/cloud-foundation-fabric//blueprints/data-solutions/data-platform-foundations?ref=v29.0.0"
  organization_domain = var.organization.domain
  project_config = {
    parent         = google_folder.data_cloud.id
    project_create = false
    project_ids    = {
      drop     = module.projects.projects["drp"].id
      load     = module.projects.projects["lod"].id
      orc      = module.projects.projects["orc"].id
      trf      = module.projects.projects["trf"].id
      dwh-lnd  = module.projects.projects["lnd"].id
      dwh-cur  = module.projects.projects["cur"].id
      dwh-conf = module.projects.projects["cnf"].id
      common   = module.projects.projects["cmn"].id
      exp      = module.projects.projects["exp"].id
    }
  }
  prefix         = var.prefix

  groups = {
    data-analysts  = google_cloud_identity_group.data_analysts.display_name
    data-engineers = google_cloud_identity_group.data_engineers.display_name
    data-security  = google_cloud_identity_group.data_security.display_name
  }

  location = lower(var.locations.bq)
  region   = var.region

  composer_config = {
    disable_deployment = true
  }
}
