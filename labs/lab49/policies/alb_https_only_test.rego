package terraform.aws.alb_test

import rego.v1

import data.terraform.aws.alb

test_http_listener_debe_ser_rechazado if {
  count(alb.deny) == 1 with input as {
    "resource_changes": [{
      "address": "aws_lb_listener.frontend_insecure",
      "type": "aws_lb_listener",
      "change": {
        "actions": ["create"],
        "before": null,
        "after": {"port": 80, "protocol": "HTTP"}
      }
    }]
  }
}

test_https_listener_debe_pasar if {
  count(alb.deny) == 0 with input as {
    "resource_changes": [{
      "address": "aws_lb_listener.frontend_secure",
      "type": "aws_lb_listener",
      "change": {
        "actions": ["create"],
        "before": null,
        "after": {"port": 443, "protocol": "HTTPS"}
      }
    }]
  }
}

test_plan_sin_listeners_debe_pasar if {
  count(alb.deny) == 0 with input as {
    "resource_changes": [{
      "address": "aws_vpc.main",
      "type": "aws_vpc",
      "change": {
        "actions": ["create"],
        "before": null,
        "after": {"cidr_block": "10.49.0.0/16"}
      }
    }]
  }
}

test_destruccion_http_debe_pasar if {
  count(alb.deny) == 0 with input as {
    "resource_changes": [{
      "address": "aws_lb_listener.legacy_http",
      "type": "aws_lb_listener",
      "change": {
        "actions": ["delete"],
        "before": {"port": 80, "protocol": "HTTP"},
        "after": null
      }
    }]
  }
}

test_multiples_listeners_cuenta_violaciones if {
  count(alb.deny) == 2 with input as {
    "resource_changes": [
      {
        "address": "aws_lb_listener.https_ok",
        "type": "aws_lb_listener",
        "change": {
          "actions": ["create"],
          "before": null,
          "after": {"port": 443, "protocol": "HTTPS"}
        }
      },
      {
        "address": "aws_lb_listener.http_bad_1",
        "type": "aws_lb_listener",
        "change": {
          "actions": ["create"],
          "before": null,
          "after": {"port": 80, "protocol": "HTTP"}
        }
      },
      {
        "address": "aws_lb_listener.http_bad_2",
        "type": "aws_lb_listener",
        "change": {
          "actions": ["update"],
          "before": {"port": 443, "protocol": "HTTPS"},
          "after": {"port": 80, "protocol": "HTTP"}
        }
      }
    ]
  }
}
