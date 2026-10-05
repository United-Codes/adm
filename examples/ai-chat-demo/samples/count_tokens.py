#!/usr/bin/env python3
"""Counts the embedding tokens of the chunks exported by db/17_aic_export_chunks.sql.

    pip install tiktoken
    python3 count_tokens.py ../db/chunks.csv

text-embedding-3-small and -large use the cl100k_base encoding. The price per million tokens is not
in the script on purpose: it changes. Look it up at the provider and multiply.
"""
import csv
import sys

import tiktoken

enc = tiktoken.get_encoding("cl100k_base")
per_collection, chunks = {}, 0
with open(sys.argv[1] if len(sys.argv) > 1 else "chunks.csv") as f:
    for row in csv.reader(f):
        if len(row) < 5 or row[0] == "COLLECTION_NAME":
            continue
        tokens = len(enc.encode(row[4].replace("\\n", "\n")))
        per_collection[row[0]] = per_collection.get(row[0], 0) + tokens
        chunks += 1
for name, tokens in sorted(per_collection.items()):
    print(f"{name:16} {tokens:6} tokens")
print(f"{'total':16} {sum(per_collection.values()):6} tokens in {chunks} chunks")
