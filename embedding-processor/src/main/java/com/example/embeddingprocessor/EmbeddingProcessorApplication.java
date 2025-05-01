package com.example.embeddingprocessor;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Bean;
import org.springframework.messaging.Message;
import org.springframework.messaging.support.MessageBuilder;
import org.springframework.ai.embedding.EmbeddingRequest;
import org.springframework.ai.embedding.EmbeddingResponse;
import org.springframework.ai.ollama.OllamaEmbeddingModel;
import org.springframework.ai.ollama.api.OllamaOptions;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Function;

/**
 * Spring Cloud Stream processor that generates vector embeddings from text using Ollama's nomic-embed-text model.
 *
 * Receives: Message<String> (PDF text, with optional filename header)
 * Emits: Message<Map<String, Object>> (embedding vector, original text, filename)
 */
@SpringBootApplication
public class EmbeddingProcessorApplication {

    private static final Logger log = LoggerFactory.getLogger(EmbeddingProcessorApplication.class);

    public static void main(String[] args) {
        SpringApplication.run(EmbeddingProcessorApplication.class, args);
    }

    /**
     * Processor function that takes extracted text and generates an embedding vector using Ollama.
     * The output message contains:
     *   - embedding: the vector
     *   - text: the original input text
     *   - filename: original filename header if present
     */
    @Bean
    public Function<Message<String>, Message<Map<String, Object>>> input(OllamaEmbeddingModel embeddingModel) {
        return message -> {
            String text = message.getPayload();
            String filename = message.getHeaders().getOrDefault("filename", "unknown").toString();
            log.info("[EMBED] Received text for embedding (filename: {}), length: {}", filename, text.length());
            try {
                OllamaOptions options = OllamaOptions.builder().build();
                EmbeddingRequest request = new EmbeddingRequest(List.of(text), options);
                EmbeddingResponse response = embeddingModel.call(request);
                float[] embeddingArray = response.getResults().get(0).getOutput();
                List<Double> embedding = new ArrayList<>();
                for (float v : embeddingArray) embedding.add((double) v);
                Map<String, Object> output = new HashMap<>();
                output.put("embedding", embedding);
                output.put("text", text);
                output.put("filename", filename);
                return MessageBuilder.withPayload(output).copyHeaders(message.getHeaders()).build();
            } catch (Exception e) {
                log.error("Failed to generate embedding: {}", e.getMessage(), e);
                Map<String, Object> error = new HashMap<>();
                error.put("error", e.getMessage());
                error.put("text", text);
                error.put("filename", filename);
                return MessageBuilder.withPayload(error).copyHeaders(message.getHeaders()).build();
            }
        };
    }
}
