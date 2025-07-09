# SCDF-RAG: Spring Cloud Data Flow RAG Pipeline Manager

A comprehensive toolkit for managing RAG (Retrieval-Augmented Generation) pipelines using Spring Cloud Data Flow. The core component is `rag-stream.sh`, which provides an interactive interface for deploying, managing, and monitoring RAG processing streams.

<p align="center">
  <img src="images/logo.png" alt="SCDF-RAG Logo" width="300"/>
</p>

## 🎯 Core Features

- **Interactive Stream Management**: Deploy, monitor, and manage RAG pipelines through an intuitive menu system
- **Multi-Environment Support**: Configure different settings for development, staging, and production
- **Automatic App Registration**: Dynamically fetch and register the latest versions of custom processors from GitHub
- **Version-Aware Operations**: Display app versions during registration and deployment
- **Comprehensive Logging**: Detailed logging with context-aware error handling
- **Token Caching**: Persistent authentication with automatic token refresh
- **Instance Scaling**: Configure and scale processor instances for optimal performance

## 🚀 Quick Start

### Prerequisites

Install required tools:
```bash
# macOS
brew install kubectl helm yq jq curl

# Linux
sudo apt-get install kubectl helm yq jq curl
```

### Setup

1. **Clone the repository**:
   ```bash
   git clone <repository-url>
   cd SCDF-RAG
   ```

2. **Configure your environment**:
   ```bash
   cp config.template.yaml config.yaml
   # Edit config.yaml with your SCDF server details
   ```

3. **Run the interactive manager**:
   ```bash
   ./rag-stream.sh
   ```

## 📋 Main Menu Options

The `rag-stream.sh` script provides an interactive menu with these options:

- **View custom apps** - Display registered apps with versions
- **Unregister and register custom apps** - Refresh app registrations
- **Delete stream** - Remove existing streams
- **Create stream definition only** - Define stream without deployment
- **Deploy stream only** - Deploy existing stream definition
- **Create and deploy stream** - Complete stream lifecycle
- **Full process** - Complete refresh (delete → register apps → create → deploy)
- **Show stream status** - Monitor stream and app health
- **Launch testing menu** - Test different pipeline configurations

## 🔧 Configuration

### Environment Configuration

The system uses a hierarchical configuration approach:

1. **Default settings** in `config.yaml`
2. **Environment-specific overrides** (e.g., `production` section)
3. **Environment variable overrides**

```yaml
# config.yaml
default:
  scdf:
    url: "https://your-scdf-server.com"
    token_url: "https://your-oauth-server.com/oauth/token"
  
  apps:
    hdfsWatcher:
      type: "source"
      github_url: "https://github.com/dbbaskette/hdfsWatcher"
    textProc:
      type: "processor" 
      github_url: "https://github.com/dbbaskette/textProc"
    embedProc:
      type: "processor"
      github_url: "https://github.com/dbbaskette/embedProc"

  stream:
    name: "rag-stream"
    definition: "hdfsWatcher | textProc | embedProc | log"
    deployment_properties:
      deployer.textProc.count: 1
      deployer.embedProc.count: 4
      # ... additional properties
```

### Environment-Specific Settings

```bash
# Use production environment
./rag-stream.sh --env production

# Use custom environment
./rag-stream.sh --env staging
```

## 🔄 RAG Pipeline Components

### Core Applications

- **hdfsWatcher** (Source): Monitors HDFS for new documents
- **textProc** (Processor): Extracts and processes text content
- **embedProc** (Processor): Generates vector embeddings
- **log** (Sink): Outputs results for monitoring

### Pipeline Flow

```
HDFS Documents → hdfsWatcher → textProc → embedProc → log
```

## 🛠️ Advanced Usage

### Command Line Options

```bash
./rag-stream.sh [options]

Options:
  --no-prompt    Run full process automatically
  --tests        Launch testing menu
  --help         Show help message
  --debug        Enable debug logging
  --env <env>    Specify environment (default, production, etc.)
```

### Testing Different Configurations

```bash
# Launch testing menu
./rag-stream.sh --tests

# Test HDFS pipeline
./rag-stream.sh --tests
# Then select option 1: Test HDFS (hdfsWatcher → log)

# Test TextProc pipeline  
./rag-stream.sh --tests
# Then select option 2: Test TextProc (hdfsWatcher → textProc → log)
```

### Instance Scaling

Control the number of processor instances:

```yaml
# In config.yaml
deployment_properties:
  deployer.textProc.count: 2    # 2 textProc instances
  deployer.embedProc.count: 4   # 4 embedProc instances
```

### Environment Variables

Override any configuration setting:

```bash
export SCDF_URL="https://my-scdf-server.com"
export SCDF_TOKEN_URL="https://my-oauth-server.com/oauth/token"
./rag-stream.sh
```

## 📊 Monitoring and Logs

### Stream Status

Check stream and app health:
```bash
./rag-stream.sh
# Select option 8: Show stream status
```

### Logs

All operations are logged to `logs/rag-stream-YYYYMMDD-HHMMSS.log` with:
- Timestamps and context
- Success/error status
- API responses
- Configuration details

### Debug Mode

Enable detailed logging:
```bash
./rag-stream.sh --debug
```

## 🔐 Authentication

The system supports OAuth2 token-based authentication:

1. **Token Caching**: Tokens are stored in `.cf_token` and reused
2. **Automatic Refresh**: Invalid tokens trigger new authentication
3. **Secure Storage**: Token files have restricted permissions

## 🏗️ Architecture

### File Structure

```
SCDF-RAG/
├── rag-stream.sh              # Main interactive manager
├── config.yaml                # Configuration (create from template)
├── config.template.yaml       # Configuration template
├── functions/                 # Modular function libraries
│   ├── config.sh             # Configuration management
│   ├── auth.sh               # Authentication handling
│   ├── rag_apps.sh           # App registration
│   ├── rag_streams.sh        # Stream operations
│   └── utilities.sh          # Utility functions
├── logs/                     # Operation logs
└── resources/                # Additional resources
```

### Key Components

- **Configuration Management**: Hierarchical config with environment support
- **App Registration**: Dynamic GitHub release fetching and registration
- **Stream Operations**: Create, deploy, monitor, and manage streams
- **Error Handling**: Comprehensive error handling with retry logic
- **Logging**: Context-aware logging with file and console output

## 🔧 Development

### Adding New Apps

1. Add app definition to `config.yaml`:
   ```yaml
   apps:
     myNewApp:
       type: "processor"
       github_url: "https://github.com/your-org/your-app"
   ```

2. The system will automatically:
   - Fetch the latest release from GitHub
   - Register the app with SCDF
   - Display version information

### Customizing Deployment Properties

Modify `deployment_properties` in `config.yaml`:

```yaml
deployment_properties:
  # Instance scaling
  deployer.textProc.count: 2
  deployer.embedProc.count: 4
  
  # Memory allocation
  deployer.textProc.memory: "4096M"
  deployer.embedProc.memory: "2048M"
  
  # Custom properties
  app.textProc.custom.property: "value"
```

## 📝 Legacy Components

> **Note**: The SCDF installation scripts (`scdf_install_k8s.sh`) are legacy components from an older version. The core functionality is now focused on stream management via `rag-stream.sh`.

For SCDF installation, refer to the [Spring Cloud Data Flow documentation](https://dataflow.spring.io/docs/installation/).

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## 📄 License

MIT License - see LICENSE file for details.

---

**Core Component**: `rag-stream.sh` - Interactive RAG pipeline management  
**Configuration**: `config.yaml` - Environment-specific settings  
**Documentation**: See inline comments and function documentation
