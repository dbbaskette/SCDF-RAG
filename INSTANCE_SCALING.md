# Instance Scaling for SCDF RAG Stream

This document explains how to control the number of instances for `textProc` and `embedProc` applications in your SCDF RAG stream using the new deployment properties.

## Overview

The SCDF RAG stream system now supports deployment properties that allow you to control the number of instances for each application in the stream. This is particularly useful for scaling the processing capacity of `textProc` and `embedProc` applications.

## Configuration

### Default Configuration

In your `config.yaml` file, you can specify instance counts in the deployment properties section:

```yaml
default:
  stream:
    deployment_properties:
      # Instance scaling for processors
      deployer.textProc.cloudfoundry.instances: 1
      deployer.embedProc.cloudfoundry.instances: 1
      
      # Other deployment properties...
      deployer.hdfsWatcher.cloudfoundry.disk: "1024M"
      deployer.hdfsWatcher.cloudfoundry.memory: "1024M"
```

### Environment-Specific Configuration

You can override instance counts for different environments:

```yaml
production:
  stream:
    deployment_properties:
      # Higher instance counts for production
      deployer.textProc.cloudfoundry.instances: 3
      deployer.embedProc.cloudfoundry.instances: 2
      deployer.hdfsWatcher.cloudfoundry.instances: 2
```

## Usage Examples

### 1. Deploy with Default Instance Counts

```bash
# Deploy using default configuration (1 instance each)
./rag-stream.sh --env default
```

### 2. Deploy with Custom Instance Counts

```bash
# Deploy with 2 textProc and 3 embedProc instances
./functions/instance_scaling.sh deploy 2 3 production
```

### 3. Scale Existing Stream

```bash
# Scale an existing stream to 4 textProc and 2 embedProc instances
./functions/instance_scaling.sh scale 4 2
```

### 4. Show Current Deployment Properties

```bash
# Show deployment properties for a specific environment
./functions/instance_scaling.sh show production
```

## Available Properties

### textProc Instance Control
- **Property**: `deployer.textProc.cloudfoundry.instances`
- **Type**: Integer
- **Default**: 1
- **Description**: Controls the number of textProc instances

### embedProc Instance Control
- **Property**: `deployer.embedProc.cloudfoundry.instances`
- **Type**: Integer
- **Default**: 1
- **Description**: Controls the number of embedProc instances

### hdfsWatcher Instance Control
- **Property**: `deployer.hdfsWatcher.count`
- **Type**: Integer
- **Default**: 1 (should not be changed)
- **Description**: Controls the number of hdfsWatcher instances. **WARNING**: Should typically remain at 1 to avoid duplicate file processing.

## Scaling Considerations

### When to Scale Up
- **textProc**: Scale up when you have high document processing volume
- **embedProc**: Scale up when you have high embedding generation requirements
- **hdfsWatcher**: **DO NOT SCALE** - Keep at 1 instance to avoid duplicate file processing

### Performance Impact
- **textProc**: Each instance processes documents independently
- **embedProc**: Each instance generates embeddings independently
- **hdfsWatcher**: Single instance monitors for new files (scaling causes duplicate processing)
- **Memory Usage**: More instances = more memory consumption
- **CPU Usage**: More instances = more CPU consumption

### Best Practices
1. **Start Small**: Begin with 1 instance each and scale up as needed
2. **Monitor Performance**: Use SCDF dashboard to monitor application performance
3. **Environment-Specific**: Use different instance counts for dev/staging/production
4. **Resource Limits**: Consider your Cloud Foundry resource limits
5. **Source Applications**: Keep source applications (like hdfsWatcher) at 1 instance to avoid duplicate processing

## Troubleshooting

### Common Issues

1. **Insufficient Resources**
   ```
   Error: Insufficient memory/disk for requested instances
   ```
   **Solution**: Reduce instance counts or increase resource limits

2. **Deployment Timeout**
   ```
   Error: Deployment timeout
   ```
   **Solution**: Increase startup timeout or reduce instance counts

3. **Instance Scaling Fails**
   ```
   Error: Failed to scale application
   ```
   **Solution**: Check if stream is deployed and running

### Debugging Commands

```bash
# Check stream status
./rag-stream.sh --status

# Show instance counts
./functions/instance_scaling.sh show default

# Check application logs
./rag-stream.sh --logs
```

## Advanced Usage

### Dynamic Scaling

You can programmatically scale instances based on load:

```bash
#!/bin/bash
# Example: Scale based on queue depth
QUEUE_DEPTH=$(get_queue_depth)
if [ "$QUEUE_DEPTH" -gt 100 ]; then
    ./functions/instance_scaling.sh scale 3 2
elif [ "$QUEUE_DEPTH" -lt 10 ]; then
    ./functions/instance_scaling.sh scale 1 1
fi
```

### Environment Variable Overrides

You can override instance counts using environment variables:

```bash
export TEXT_PROC_INSTANCES=3
export EMBED_PROC_INSTANCES=2
./rag-stream.sh --env production
```

## Related Files

- `config.yaml` - Main configuration file
- `config.template.yaml` - Template configuration file
- `functions/instance_scaling.sh` - Scaling utility script
- `functions/utilities.sh` - Utility functions for scaling
- `functions/rag_streams.sh` - Stream management functions 