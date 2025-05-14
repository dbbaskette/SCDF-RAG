-- Table for storing embedded items for RAG pipeline
-- 'embedding' column dimension must match the output of your embedding model (e.g., 768 for nomic-embed-text, 1536 for phi3)
CREATE TABLE items (
    id SERIAL PRIMARY KEY,          -- Or UUID, or any other unique identifier
    content TEXT,                   -- The original text content that was embedded (optional, but useful)
    embedding vector(768)           -- Replace 768 with the actual dimension of your embeddings
);