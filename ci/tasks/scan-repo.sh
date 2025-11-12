#!/bin/bash

cd telemetry-release || exit

grype . --scope AllLayers --add-cpes-if-none --fail-on "negligible" -vv
