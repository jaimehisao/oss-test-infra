# Copyright 2021 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

resource "google_monitoring_alert_policy" "predicted-gh-rate-limit-exhaustion" {
  project      = var.project
  display_name = "predicted-gh-rate-limit-exhaustion"
  combiner     = "OR" # required

  conditions {
    display_name = "predicted-gh-rate-limit-exhaustion"

    condition_monitoring_query_language {
      # This query calculates the expected remaining rate limit tokens at the
      # end of the current rate limit reset window based on rate of consumption
      # over the last 10 minutes. The alert fires if we predict that we will
      # come within 250 tokens of the limit (which is 5% of the 5000 limit).
      duration = "0s"
      query    = <<-EOT
      {t_0: # The remaining tokens in the rate limit reset window
          fetch k8s_container::workload.googleapis.com/github_token_usage
          ;
      t_1: # The expected tokens that will be used over the remaining time in the rate limit reset window based on recent usage.
          fetch k8s_container
          | {
              metric 'workload.googleapis.com/github_token_usage'
              | value 5000 - val()
              | align rate(1m) # Align rate over 1m and filter before actual 10m aggregation to drop counter resets in gauge.
              | filter val() > 0
              | align mean_aligner(10m)
              ;
              metric 'workload.googleapis.com/github_token_reset'
              | value val() / (1000000000)
          }
          | outer_join 0
          | mul
      }
      | outer_join 0
      | sub # Result is the expected remaining tokens at the end of the rate limit reset window.
      | every 1m
      | filter val() < 250
      EOT
      trigger {
        count = 1
      }
    }
  }

  documentation {
    content   = "One of the GitHub tokens used with `ghproxy` is predicted to exhaust its rate limit before the end of the rate limit reset window."
    mime_type = "text/markdown"
  }

  # gcloud beta monitoring channels list --project=oss-prow
  notification_channels = ["projects/${var.project}/notificationChannels/${var.notification_channel_id}"]
}

resource "google_monitoring_alert_policy" "pod-crashlooping" {
  for_each     = var.prow_components
  project      = var.project
  display_name = "pod-crashlooping-${each.key}"
  combiner     = "OR" # required

  conditions {
    display_name = "pod-crashlooping-${each.key}"

    condition_monitoring_query_language {
      # Alert if the service crashlooped, which results in restarts with exponential backoff.
      # This threshold is higher than the default crashloop backoff threshold, mainly due to
      # the fact prow components would crashloop when kubernetes master is upgrading, which
      # normally takes 5 minutes. Setting this to 12 minutes for excluding this case
      duration = "720s"
      query    = <<-EOT
      fetch k8s_container
      | metric 'kubernetes.io/container/restart_count'
      | filter
          (resource.container_name == '${each.key}' && resource.namespace_name == '${each.value.namespace}')
      | align delta(6m)
      | every 6m
      | group_by [], [value_restart_count_aggregate: aggregate(value.restart_count)]
      | condition val() > 0 '1'
      EOT
      trigger {
        count = 1
      }
    }
  }

  documentation {
    content   = "The service `${each.key}` has been restarting for more than 6 minutes, very likely crashlooping."
    mime_type = "text/markdown"
  }

  # gcloud beta monitoring channels list --project=oss-prow
  notification_channels = ["projects/${var.project}/notificationChannels/${var.notification_channel_id}"]
}


resource "google_monitoring_alert_policy" "heartbeat-job-stale" {
  project      = var.project
  display_name = "heartbeat-job-stale"
  combiner     = "OR" # required

  conditions {
    display_name = "heartbeat-job-stale"

    condition_absent {
      filter   = "metric.type=\"workload.googleapis.com/prowjob_state_transitions\" resource.type=\"k8s_container\" metric.label.\"job_name\"=\"${var.heartbeat_job.job_name}\" metric.label.\"state\"=\"success\""
      duration = "${var.heartbeat_job.alert_interval}"

      aggregations { # required
        alignment_period     = "${var.heartbeat_job.interval}"
        per_series_aligner   = "ALIGN_RATE"
      }
    }
  }

  documentation {
    content   = " The heartbeat job `${var.heartbeat_job.job_name}` has not had a successful run in the past ${var.heartbeat_job.alert_interval} (should run every ${var.heartbeat_job.interval})."
    mime_type = "text/markdown"
  }

  # gcloud beta monitoring channels list --project=oss-prow
  notification_channels = ["projects/${var.project}/notificationChannels/${var.notification_channel_id}"]
}
