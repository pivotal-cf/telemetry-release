#!/bin/bash

cd telemetry-release

grype . --scope AllLayers --add-cpes-if-none --fail-on "negligible" -vv
