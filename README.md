# Spring Cloud Data Flow on Kubernetes - Automated Installer

This project provides a fully automated shell script to deploy [Spring Cloud Data Flow (SCDF)](https://dataflow.spring.io/) on a local or cloud Kubernetes cluster, using RabbitMQ and MariaDB as backing services. The script handles all setup, error checking, and default application registration for a seamless developer experience.

---

## Features

- **One-command install**: Deploys SCDF, Skipper, RabbitMQ, and MariaDB via Helm.
- **Automatic cleanup**: Removes previous installations and verifies deletion before proceeding.
- **NodePort exposure**: All management UIs are available on your localhost for easy access.
- **Default app registration**: Downloads and registers the latest default RabbitMQ stream apps via the SCDF REST API.
- **Robust error handling**: Logs all actions and errors to the `logs/` directory for easy troubleshooting.
- **Fully commented and maintainable**: The scripts are easy to follow and modify.

---

## Prerequisites

- **Kubernetes cluster** (e.g., Docker Desktop, Minikube, Kind, or cloud provider)
- **kubectl** (configured to point to your cluster)
- **Helm** (v3+ recommended)
- **curl** and **bash**

---

## Usage

1. **Clone this repo** (or copy the scripts into your project):
    ```sh
    git clone <your-fork-or-this-repo-url>
    cd SCDF-RAG
    ```

2. **Make the scripts executable**:
    ```sh
    chmod +x install_scdf_k8s.sh create_stream.sh
    ```

3. **Run the installer**:
    ```sh
    ./install_scdf_k8s.sh
    ```

4. **Deploy the PDF preprocessor stream**:
    ```sh
    ./create_stream.sh
    ```

5. **Access the management UIs:**
    - SCDF Dashboard: [http://127.0.0.1:30080/dashboard](http://127.0.0.1:30080/dashboard)
    - RabbitMQ UI: [http://127.0.0.1:31672](http://127.0.0.1:31672) (user/bitnami)
    - RabbitMQ AMQP: `localhost:30672` (user/bitnami)

6. **Check logs and troubleshoot:**
    - All actions and errors are logged in the `logs/` directory.
    - If you encounter issues, check these logs for details.

---

## What the Scripts Do

- Cleans up any previous SCDF, RabbitMQ, and namespace resources, verifying deletion before continuing.
- Installs RabbitMQ via Helm and waits for readiness.
- Installs SCDF (with Skipper and MariaDB) via Helm and waits for readiness.
- Registers default stream apps as Docker images.
- Exposes all UIs/services on NodePorts for localhost access.
- Deploys a sample PDF preprocessor stream pipeline.

---

## Logs

All logs are written to the `logs/` directory for easier troubleshooting and organization:
- `logs/install_scdf_k8s.log`
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

- If the SCDF dashboard or RabbitMQ UI is not accessible, ensure your Kubernetes cluster is running and NodePorts are not blocked by a firewall.
- Check the `logs/` directory for detailed error messages.
- If you see repeated 404s during app registration, the script will skip malformed entries and only register valid apps.

---

## References

- [Spring Cloud Data Flow Docs](https://dataflow.spring.io/docs/)
- [Bitnami SCDF Helm Chart](https://artifacthub.io/packages/helm/bitnami/spring-cloud-dataflow)
- [Bitnami RabbitMQ Helm Chart](https://artifacthub.io/packages/helm/bitnami/rabbitmq)
