#!/bin/bash
echo "Attempting to source ./scdf_env.properties..."
source ./scdf_env.properties
echo "--- Source command finished ---"
echo "Value of NAMESPACE variable is: '${NAMESPACE}'"
echo "Script complete."
