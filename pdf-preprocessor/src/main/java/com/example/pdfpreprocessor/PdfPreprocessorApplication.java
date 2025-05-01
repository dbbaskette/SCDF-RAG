package com.example.pdfpreprocessor;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Bean;
import org.springframework.messaging.Message;
import org.springframework.messaging.support.MessageBuilder;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.function.Function;

import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.text.PDFTextStripper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Spring Cloud Stream processor for extracting text from PDF files.
 *
 * <p>This application receives PDF file contents as byte arrays from a message broker (e.g., RabbitMQ),
 * reconstructs the PDF as a temporary file, extracts all text using Apache PDFBox, and emits the extracted text
 * as a new message. All headers are preserved, and a 'filename' header is added. Temporary files are deleted after processing.
 *
 * <p>If PDF extraction fails, an error message is sent as the payload and the error is logged.
 */
@SpringBootApplication
public class PdfPreprocessorApplication {
    private static final Logger log = LoggerFactory.getLogger(PdfPreprocessorApplication.class);

    public static void main(String[] args) {
        SpringApplication.run(PdfPreprocessorApplication.class, args);
    }

    /**
     * Extracts text from a PDF file received as a byte array message.
     *
     * <p>Steps:
     * <ol>
     *   <li>Receives a Message<byte[]> (PDF file contents)</li>
     *   <li>Writes the bytes to a temporary file</li>
     *   <li>Uses PDFBox to extract text from the file</li>
     *   <li>Builds a new Message<String> with the extracted text and original headers</li>
     *   <li>Deletes the temporary file</li>
     *   <li>On error, logs and emits an error message</li>
     * </ol>
     */
    @Bean
    public Function<Message<byte[]>, Message<String>> input() {
        return message -> {
            byte[] pdfBytes = message.getPayload();
            File tempFile = null;
            try {
                tempFile = File.createTempFile("input-", ".pdf");
                try (FileOutputStream fos = new FileOutputStream(tempFile)) {
                    fos.write(pdfBytes);
                }
                try (PDDocument document = PDDocument.load(tempFile)) {
                    PDFTextStripper pdfStripper = new PDFTextStripper();
                    String text = pdfStripper.getText(document);
                    log.info("[DEBUG] Successfully extracted text from file: {} ({} bytes)", tempFile.getName(), tempFile.length());
                    return MessageBuilder.withPayload(text)
                            .copyHeaders(message.getHeaders())
                            .setHeader("filename", tempFile.getName())
                            .build();
                }
            } catch (IOException e) {
                log.error("Failed to extract PDF text: {}", e.getMessage(), e);
                return MessageBuilder.withPayload("ERROR: " + e.getMessage())
                        .copyHeaders(message.getHeaders())
                        .setHeader("filename", tempFile != null ? tempFile.getName() : "unknown")
                        .build();
            } finally {
                if (tempFile != null && tempFile.exists()) {
                    tempFile.delete();
                }
            }
        };
    }
}
