<p align="center">
  <img src="images/logo.png" alt="SCDF-RAG Logo" width="300"/>
</p>

# Spring Cloud Data Flow on Kubernetes - Automated Installer

This project provides a fully automated shell script to deploy [Spring Cloud Data Flow (SCDF)](https://dataflow.spring.io/) on a local or cloud Kubernetes cluster, using RabbitMQ, PostgreSQL, MinIO, and the Ollama Nomic model as backing services. The script handles all setup, error checking, and default application registration for a seamless developer experience.

---

## Features

- **One-command install**: Deploys SCDF, Skipper, RabbitMQ, PostgreSQL, MinIO, and Ollama Nomic via Helm and dynamic YAML generation.
- **MinIO S3 integration**: Easily deploy a MinIO S3-compatible server for object storage in the SCDF namespace.
- **Ollama Nomic embedding model**: Installs the Nomic embedding model for use with SCDF pipelines, exposed via NodePort for external access.
- **Automatic cleanup**: Removes previous installations and verifies deletion before proceeding.
- **NodePort exposure**: All management UIs and Ollama API are available on your localhost for easy access.
- **Default app registration**: Downloads and registers the latest default RabbitMQ stream apps via the SCDF REST API.
- **Robust error handling**: Logs all actions and errors to the `logs/` directory for easy troubleshooting.
- **Minimal terminal output**: Only step progress, completion, and management URLs are printed to the terminal; all INFO and STATUS details are in the log file.
- **Fully commented and maintainable**: The scripts are easy to follow and modify.

---

## Usage

1. **Clone this repo** (or copy the scripts into your project):
    ```sh
    git clone <your-fork-or-this-repo-url>
    cd SCDF-RAG
    ```
2. **Make the scripts executable**:
    ```sh
    chmod +x scdf_install_k8s.sh minio_install_scdf.sh create_stream.sh
    ```
3. **Run the SCDF installer**:
    ```sh
    ./scdf_install_k8s.sh
    ```
   - This will install SCDF, Skipper, RabbitMQ, PostgreSQL, MinIO, and the Ollama Nomic model in one step.
   - Minimal output will be shown in the terminal; see `logs/scdf_install_k8s.log` for details.

### Interactive Test Mode

You can run the install script in test mode to execute or re-run individual steps using an interactive menu:

```sh
./scdf_install_k8s.sh --test
```

Menu options:

```
SCDF Install Script Test Menu
-----------------------------------
1) Cleanup previous install
2) Install PostgreSQL
3) Install MinIO
4) Install Ollama Nomic Model
5) Install Spring Cloud Data Flow (includes Skipper, chart-managed RabbitMQ)
6) Download SCDF Shell JAR
7) Display the Management URLs
q) Exit
Select a step to run [1-7, q to quit]:
```

Each step can be run independently and as many times as needed. This is useful for debugging, development, or partial deployments.

4. **(Optional) Deploy MinIO S3 server only**:
    ```sh
    ./minio_install_scdf.sh
    ```
5. **Deploy the PDF preprocessor stream**:
    ```sh
    ./create_stream.sh
    ```
6. **Access the management UIs:**
    - SCDF Dashboard: [http://127.0.0.1:30080/dashboard](http://127.0.0.1:30080/dashboard)
    - RabbitMQ UI: [http://127.0.0.1:31672](http://127.0.0.1:31672) (user/bitnami)
    - RabbitMQ AMQP: `localhost:30672` (user/bitnami)
    - MinIO Console: [http://127.0.0.1:30901](http://127.0.0.1:30901)
    - Ollama Nomic: [http://127.0.0.1:31434](http://127.0.0.1:31434)
7. **Check logs and troubleshoot:**
    - All actions and errors are logged in the `logs/` directory.
    - If you encounter issues, check these logs for details.

---

## Changes in this Version

- Ollama Nomic model install is now automated and included in the main install flow.
- MinIO install is restored and part of the default install.
- All INFO and STATUS messages are now logged only; the terminal shows only step progress, completion, and management URLs.
- All NodePorts and management URLs are dynamically generated and shown at the end of the install.
- **RabbitMQ NodePort configuration:** The installer now sets RabbitMQ's AMQP and management UI NodePorts from your `scdf_env.properties` file, ensuring your chosen ports are always used.

---

## Prerequisites

Before running the SCDF install script or related automation, ensure the following tools are installed on your system:

- `kubectl` (Kubernetes CLI)
- `helm` (Helm package manager)
- `yq` (YAML processor)

### Install with Homebrew (macOS):

```sh
brew install kubectl helm yq
```

### Install on Linux (example):

```sh
# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# yq
sudo wget -O /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq
```

If any of these tools are missing, the install script will exit with an error and prompt you to install them.

---

## What the Scripts Do

### `scdf_install_k8s.sh`
This script automates the full installation of Spring Cloud Data Flow and all required backing services on Kubernetes. Major features:
- **Installs PostgreSQL, RabbitMQ, MinIO, Ollama Nomic model, SCDF, and Skipper** using Helm and dynamic YAML generation.
- **Step-by-step progress** with clear logging and error handling.
- **Interactive test mode** (`--test`) lets you run each step independently (cleanup, install PostgreSQL, install MinIO, install Ollama, install SCDF, download SCDF Shell JAR, display management URLs).
- **Automatic cleanup**: Removes previous installs and verifies deletion before proceeding.
- **Management URLs**: Prints all important endpoints (SCDF dashboard, RabbitMQ, MinIO, Ollama) at the end.
- **Configurable via `scdf_env.properties`** for cluster-wide/environment settings.

#### Usage
```sh
./scdf_install_k8s.sh           # Full install with minimal terminal output
./scdf_install_k8s.sh --test    # Interactive menu mode for step-by-step control
```

### `create_stream.sh`
This script automates the creation, registration, and deployment of SCDF streams using only REST API calls. It supports both batch and interactive/test modes, and is fully documented for clarity.
- **Registers source, processor, and sink apps** (including custom Docker images for textProc and embedProc)
- **Builds and submits stream definitions** for pipelines like `s3 | textProc | embedProc | log`
- **Configures all deploy properties and bindings** for correct message routing
- **Interactive menu** (`--test`) lets you:
  - Destroy streams
  - Register/unregister processor or default apps
  - Create or deploy stream definitions
  - View stream/app status
  - Run test pipelines (S3→log, S3→textProc→embedProc→log)
- **Test mode for embedding processor** (`--test-embed`) creates a file→embedProc→log test stream
- **Configurable via `create_stream.properties`** for stream/app-specific settings

#### Usage
```sh
./create_stream.sh              # Full pipeline: destroy, register, create, deploy, view
./create_stream.sh --test       # Interactive menu for step-by-step stream management
./create_stream.sh --test-embed # Deploys a test stream for embedding processor verification
```

#### Example: textProc + embedProc Pipeline
The main test pipeline is:
```
s3 | textProc | embedProc | log
```
- **s3**: Reads files from MinIO/S3.
- **textProc**: Processes text (see below).
- **embedProc**: Generates vector embeddings (see below).
- **log**: Outputs results for inspection.

---

## Processor Apps in the Pipeline

### [textProc](https://github.com/dbbaskette/textProc)
- Custom Spring Cloud Stream processor for text extraction, normalization, or enrichment.
- Consumes text from the S3 source, processes it, and emits to the next stage (embedProc).
- Docker image: `dbbaskette/textproc`
- Used as the first processor in the main pipeline.

### [embedProc](https://github.com/dbbaskette/embedProc)
- Custom Spring Cloud Stream processor for generating vector embeddings from text (e.g., using Ollama Nomic model).
- Consumes processed text from textProc, calls the embedding model, and emits enriched messages downstream.
- Docker image: `dbbaskette/embedproc`
- Used as the second processor in the main pipeline.

Both processor apps are registered and managed via `create_stream.sh`, and can be updated independently. Their source code, Dockerfiles, and build instructions are available in their respective repositories.

---


- Cleans up any previous SCDF, RabbitMQ, and namespace resources, verifying deletion before continuing.
- Installs RabbitMQ via Helm and waits for readiness.
- Installs SCDF (with Skipper and PostgreSQL) via Helm and waits for readiness.
- Registers default stream apps as Docker images.
- Exposes all UIs/services on NodePorts for localhost access.
- Deploys a sample PDF preprocessor stream pipeline.
- Optionally deploys a MinIO S3-compatible server in the SCDF namespace for object storage.

---

## MinIO S3 Integration (Static hostPath)

This project uses a static PersistentVolume and PersistentVolumeClaim for MinIO, mapped to a host directory for reliable, local storage. This avoids dynamic provisioning issues and ensures data persists on your machine.

- **YAML location:** `resources/minio-pv-pvc.yaml` (auto-generated by the script)
- **Host path:** Set at runtime via `$MINIO_SOURCE_DIR` or defaults to `./sourceDocs` in your project root
- **Script:** `minio_install_scdf.sh` handles all cleanup, PV/PVC creation, and Helm install.

**How it works:**
1. Deletes any existing MinIO PVC/PV to avoid StorageClass mismatches.
2. Generates and applies the static PV/PVC YAML in `resources/`.
3. Installs MinIO via Helm, referencing the pre-created PVC (no storageClass set in Helm command).

**To deploy MinIO:**
```sh
./minio_install_scdf.sh
```

- To use a custom host path, run:
  ```sh
  MINIO_SOURCE_DIR=/your/custom/path ./minio_install_scdf.sh
  ```

---

## SCDF S3-to-Log Stream Setup

This project contains scripts and configuration to deploy a Spring Cloud Data Flow (SCDF) stream that reads files from an S3/MinIO bucket and writes them to a log sink, using RabbitMQ as the message broker.

### Files

- `create_stream.sh`  
  Bash script to create and deploy the SCDF stream. Reads all configuration from `create_stream.properties`.
- `create_stream.properties`  
  Properties file containing all configurable settings for S3/MinIO, RabbitMQ, and SCDF.

### Usage

---

## Script Functions and Internals

The `create_stream.sh` script is now thoroughly documented for maintainers and advanced users. Each function includes a block docstring and inline comments to explain its purpose, arguments, and implementation details. This makes it easy to understand, modify, and debug the stream automation pipeline.

### Key Functions:

- **set_minio_creds**: Fetches MinIO (S3) credentials from Kubernetes secrets and exports them as environment variables.
- **source_properties**: Loads cluster and stream configuration from `scdf_env.properties` and `create_stream.properties`.
- **build_json_from_props**: Converts a comma-separated string of key=value pairs into a JSON object for SCDF REST API deploy requests, with special handling for environment variable formatting.
- **extract_and_log_api_messages**: Parses and logs errors/warnings from SCDF REST API responses.
- **step_destroy_stream**: Removes any existing SCDF stream deployment, definition, and orphaned Kubernetes resources.
- **step_register_processor_apps**: Registers all custom processor apps as SCDF processor apps using Docker image URIs.
- **step_register_default_apps**: Registers default source (S3) and sink (log) apps using Maven URIs, and sets their options.
- **step_create_stream_definition**: Builds and submits the stream definition to SCDF via REST API.
- **step_deploy_stream**: Builds deploy properties, converts them to JSON, and submits the deploy request to SCDF.
- **test_textproc_pipeline**: Creates and deploys a test stream (`s3 | textProc | log`), setting all required bindings, credentials, and logging. Useful for end-to-end pipeline verification and troubleshooting.

All functions are designed for modular use and robust error handling. See the script source for detailed documentation.

---

1. **Edit `create_stream.properties`**
    - Set your S3/MinIO endpoint, bucket, and credentials.
    - Set your RabbitMQ host and credentials (e.g., `RABBIT_USER`, `RABBIT_PASS`).
    - Set SCDF connection details.
2. **Run the script:**
    ```sh
    ./create_stream.sh
    ```
    The script will:
    - Print debug info about the current configuration.
    - Destroy and recreate the stream in SCDF.
    - Bind all apps in the stream to the correct RabbitMQ service.
    - Log actions to `logs/create_stream.log`.

### Requirements
- Bash
- AWS CLI (for S3/MinIO testing)
- `spring-cloud-dataflow-shell.jar` (must be present in the working directory)
- Access to your SCDF and RabbitMQ services

### Notes
- All sensitive credentials are redacted in logs.
- To change any configuration, edit `create_stream.properties` and re-run the script.
- The script is designed to be easily portable for local or Kubernetes-based SCDF environments.

---

For more details, see comments at the top of `create_stream.sh`.

---

## Logs

All logs are written to the `logs/` directory for easier troubleshooting and organization:
- `logs/scdf_install_k8s.log`
- `logs/create_stream.log`

---

## Customization

You can modify the scripts to change namespaces, image versions, stream definitions, and more. The scripts are fully commented for easy maintenance.

---

## License

MIT License

---

## Contributors

- [Your Name Here]

PRs and issues welcome!

---

## Uninstall / Cleanup

To remove all deployed resources:
```sh
kubectl delete namespace scdf
```
Or, rerun the script—it will clean up before reinstalling.

---

## Troubleshooting

- If the SCDF dashboard, RabbitMQ UI, or MinIO Console is not accessible, ensure your Kubernetes cluster is running and NodePorts are not blocked by a firewall.
- Check the `logs/` directory for detailed error messages.
- If you see repeated 404s during app registration, the script will skip malformed entries and only register valid apps.

---

## References

- [Spring Cloud Data Flow Docs](https://dataflow.spring.io/docs/)
- [Bitnami SCDF Helm Chart](https://artifacthub.io/packages/helm/bitnami/spring-cloud-dataflow)
- [Bitnami RabbitMQ Helm Chart](https://artifacthub.io/packages/helm/bitnami/rabbitmq)
- [MinIO Helm Chart](https://artifacthub.io/packages/helm/minio/minio)
