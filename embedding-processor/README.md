# Embedding Processor

A Spring Cloud Stream processor that generates vector embeddings from text using Spring AI and a local Ollama instance (nomic-embed-text model).

## Features
- Listens for text messages (e.g., output from pdf-preprocessor)
- Uses Ollama's nomic-embed-text model to generate embeddings
- Outputs a message with the embedding vector, original text, and filename
- Ready for integration in an SCDF pipeline

## Requirements
- Java 17+
- [Ollama](https://ollama.com/) running locally with the `nomic-embed-text` model downloaded:
  ```sh
  ollama pull nomic-embed-text
  ollama serve
  ```
- RabbitMQ (as used by your SCDF deployment)

## Configuration
Edit `src/main/resources/application.properties` as needed:

```
spring.ai.ollama.embedding.model=nomic-embed-text
spring.ai.ollama.base-url=http://localhost:11434
spring.cloud.stream.bindings.embedText-in-0.destination=pdf-text
spring.cloud.stream.bindings.embedText-in-0.group=embedding
spring.cloud.stream.bindings.embedText-out-0.destination=embeddings
```

## How it works
- Receives a message with PDF text as payload (and optional `filename` header)
- Calls Ollama's embedding API to generate a vector embedding
- Emits a message with:
  - `embedding`: the vector
  - `text`: the original text
  - `filename`: the filename (if provided)

## Usage
1. Build the app:
   ```sh
   mvn clean package
   ```
2. Run as a Spring Cloud Stream app, or register as a processor in SCDF.

## Example Output
```
{
  "embedding": [0.123, 0.456, ...],
  "text": "...original PDF text...",
  "filename": "example.pdf"
}
```

---
See [Spring AI Ollama Embeddings docs](https://docs.spring.io/spring-ai/reference/api/embeddings/ollama-embeddings.html) for more info.
