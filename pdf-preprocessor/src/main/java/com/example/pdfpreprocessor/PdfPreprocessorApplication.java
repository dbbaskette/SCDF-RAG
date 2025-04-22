package com.example.pdfpreprocessor;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Bean;
import org.springframework.messaging.Message;
import org.springframework.messaging.support.MessageBuilder;

import java.io.File;
import java.io.IOException;
import java.util.function.Function;

import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.text.PDFTextStripper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

@SpringBootApplication
public class PdfPreprocessorApplication {
    private static final Logger log = LoggerFactory.getLogger(PdfPreprocessorApplication.class);

    public static void main(String[] args) {
        SpringApplication.run(PdfPreprocessorApplication.class, args);
    }

    /**
     * Receives a Message with a File reference (from file-source), extracts text from the PDF,
     * and emits a Message<String> with the extracted text.
     */
    @Bean
    public Function<Message<File>, Message<String>> extractPdfText() {
        return message -> {
            File pdfFile = message.getPayload();
            try (PDDocument document = PDDocument.load(pdfFile)) {
                PDFTextStripper pdfStripper = new PDFTextStripper();
                String text = pdfStripper.getText(document);
                return MessageBuilder.withPayload(text)
                        .copyHeaders(message.getHeaders())
                        .setHeader("filename", pdfFile.getName())
                        .build();
            } catch (IOException e) {
                log.error("Failed to extract PDF text from {}: {}", pdfFile, e.getMessage(), e);
                return MessageBuilder.withPayload("ERROR: " + e.getMessage())
                        .copyHeaders(message.getHeaders())
                        .setHeader("filename", pdfFile.getName())
                        .build();
            }
        };
    }
}
