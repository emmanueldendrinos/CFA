# CFA Stage 2 Local Evidence

Curated local evidence. Raw CoinGecko JSON and raw GDELT archives remain under Documents\CFA-local and outside Git.

## CoinGecko / Kraken bridge evidence

- Evidence run: 20260825-224150-df65e8ab5291433094e458636aef07af
- Candidate assets: 435
- Unique current Kraken pair bridges: 322
- Multiple current Kraken pair bridges: 2
- No current Kraken pair bridge: 111
- Raw source files: 16

### Run summary

```csv
"run_id","api_tier","authentication","coins_list_records","kraken_ticker_records","ticker_pages","approved_current_kraken_pair_bridge","unverified_multiple_bridges","unverified_no_bridge","candidate_assets","retrieved_at_utc"
"20260825-224150-df65e8ab5291433094e458636aef07af","keyless_public","none","1","1420","15","322","2","111","435","2026-08-25T19:46:15.0605239+00:00"
```

### Raw source file manifest

```csv
"file_name","sha256","bytes","record_count","source_url"
"coins-list.json","2fc5c7d18c49186874c1f5d5835d17352d846f1b7829669f61aae632462419b5","2942441","1","https://api.coingecko.com/api/v3/coins/list?include_platform=true"
"kraken-tickers-page-001.json","33ecc44b73cab72694cf2f5f221e1f980c5fa927f4f305fd3f57cabf5656fe5c","63816","100","https://api.coingecko.com/api/v3/exchanges/kraken/tickers?order=base_target&dex_pair_format=symbol&page=1"
"kraken-tickers-page-002.json","0e40cfb44922fc255c2f7f96dffa65730579f623ee3c1d125971bd27a90f6aaf","64000","100","https://api.coingecko.com/api/v3/exchanges/kraken/tickers?order=base_target&dex_pair_format=symbol&page=2"
"kraken-tickers-page-003.json","9e1f4a18f00c361e9decc146cb39c135cbd70a01d7756e1bdc0075099ba5e92c","63898","100","https://api.coingecko.com/api/v3/exchanges/kraken/tickers?order=base_target&dex_pair_format=symbol&page=3"
"kraken-tickers-page-004.json","71aa515f04e7d3db9981b39edc62a665e119787ac8f1ac027d1f5b2ab8d6bb30","63893","100","https://api.coingecko.com/api/v3/exchanges/kraken/tickers?order=base_target&dex_pair_format=symbol&page=4"
"kraken-tickers-page-005.json","b57f033143380f2fa261e310d58dae35800184a8354e0e9fc3341040bd1e8fee","63773","100","https://api.coingecko.com/api/v3/exchanges/kraken/tickers?order=base_target&dex_pair_format=symbol&page=5"
"kraken-tickers-page-006.json","2de63716d146fc97e1cbabe2c75eaa078b5a272650e94f952a66ca0df946746a","63880","100","https://api.coingecko.com/api/v3/exchanges/kraken/tickers?order=base_target&dex_pair_format=symbol&page=6"
"kraken-tickers-page-007.json","a2dec3d508593bdbe07d740ee59e1d820caae39a389793c5ac53e8fdde8cd793","63774","100","https://api.coingecko.com/api/v3/exchanges/kraken/tickers?order=base_target&dex_pair_format=symbol&page=7"
"kraken-tickers-page-008.json","3cfc412fdf04dd1444c95e56070ab4a66ec7be67787f7f32f196707e9fab9193","63867","100","https://api.coingecko.com/api/v3/exchanges/kraken/tickers?order=base_target&dex_pair_format=symbol&page=8"
"kraken-tickers-page-009.json","07d349650b3d0248e52a0a691ecd7de1d52b51c092449f6855544e3d2210fbad","63832","100","https://api.coingecko.com/api/v3/exchanges/kraken/tickers?order=base_target&dex_pair_format=symbol&page=9"
"kraken-tickers-page-010.json","445f318f3cb8a40c69dac3f54a752935f883c4be11448d630a481f01af93f41d","63755","100","https://api.coingecko.com/api/v3/exchanges/kraken/tickers?order=base_target&dex_pair_format=symbol&page=10"
"kraken-tickers-page-011.json","d695df60b1269af6a6c785f923728e3fd802549242ac7076aad1fa3042364596","63754","100","https://api.coingecko.com/api/v3/exchanges/kraken/tickers?order=base_target&dex_pair_format=symbol&page=11"
"kraken-tickers-page-012.json","d6bd3dc2b0cca830a8ea8eacde2c4d53ebbe3212418904ee19cce55f025ab67e","63797","100","https://api.coingecko.com/api/v3/exchanges/kraken/tickers?order=base_target&dex_pair_format=symbol&page=12"
"kraken-tickers-page-013.json","945696c19dee160ee21dfa3ee28f7950774813aff738dd93f22fe4ee2143cddb","63798","100","https://api.coingecko.com/api/v3/exchanges/kraken/tickers?order=base_target&dex_pair_format=symbol&page=13"
"kraken-tickers-page-014.json","c7a57b699922fb9a89ee58cc10d2863e5a8e51377224484f301180e1a52287b8","63802","100","https://api.coingecko.com/api/v3/exchanges/kraken/tickers?order=base_target&dex_pair_format=symbol&page=14"
"kraken-tickers-page-015.json","7acd8f2f234c0c314b4219e74b6d677dc1e539f6ea2645894a783bd16840f0f3","12727","20","https://api.coingecko.com/api/v3/exchanges/kraken/tickers?order=base_target&dex_pair_format=symbol&page=15"
```

### CoinGecko local evidence hashes

| File | SHA-256 |
|---|---|
| run-summary.csv | 5c91ed402b5d4324cf1db314c57db22fe2300fb68a5da08b361abc513b40c3ac |
| source-files.csv | a32f3b149f5946d774a5da341062fbf9952d17cfdc3abba0bb4329910f4abddb |
| mapping-bridge-evidence.csv | 10f69735ce961a56d66738ff6c4c12aa2b4aaa304c39d9cbe78c9fa87bb3e840 |

## CFA GDELT GKG binary-safe structure inspection

- Evidence run: 20260825-230431-e6296c5ac8ce4830858bf86db45078c3

### Inspection summary

```csv
"run_id","downloaded_archive_files","selected_archives","rows_per_archive_limit","total_sampled_rows","total_utf8_invalid_rows"
"20260825-230431-e6296c5ac8ce4830858bf86db45078c3","7163","3","500","1500","0"
```

### Archive structure

```csv
"object_key","archive_file","archive_sha256","archive_bytes","zip_entry_count","inspected_entry","entry_uncompressed_bytes","entry_compressed_bytes","sampled_rows","distinct_field_counts","min_field_count","max_field_count","utf8_valid_rows","utf8_invalid_rows","crlf_rows","lf_only_rows","max_line_bytes"
"20250401000000","20250401000000.gkg.csv.zip","1134fc01972c001041b90230cc8e719d51e4a811c2e5fe9606eac65d107c9aa5","6681075","1","20250401000000.gkg.csv","20646447","6680881","500","27","27","27","500","0","0","500","33924"
"20250508081500","20250508081500.gkg.csv.zip","3971c6387efb9b3fb39bd00fac30ef3d7604c552bf422e241085133b8708f167","4520463","1","20250508081500.gkg.csv","13972695","4520269","500","27","27","27","500","0","0","500","41987"
"20250614174500","20250614174500.gkg.csv.zip","718d79c1ee6e87ffa863f41efb6593122a9b2ae464985d10be70d7cbef250d3c","3897197","1","20250614174500.gkg.csv","12177434","3897003","500","27","27","27","500","0","0","500","58731"
```

### Field-count distribution

```csv
"archive_file","entry_name","field_count","sampled_rows"
"20250401000000.gkg.csv.zip","20250401000000.gkg.csv","27","500"
"20250508081500.gkg.csv.zip","20250508081500.gkg.csv","27","500"
"20250614174500.gkg.csv.zip","20250614174500.gkg.csv","27","500"
```

The inspection counts delimiters and validates UTF-8 at the raw-byte row boundary without publishing raw news rows or assigning semantic field meanings.

- inspection-summary.csv SHA-256: bab6d37d76316fc01c247efee22ff8e0db017c93277557358ea3a6167494a648
- archive-structure.csv SHA-256: 34235b755e187acc4128071b7cd9f420795ced5236c3fcccea551d4d9a43b39d
- field-count-distribution.csv SHA-256: f2edf29e1a3bb9e6d3c09048f4ee0c9d8d40c3a769268c82ff474ccad4b4f4ba

The normalized 435-asset bridge table is published separately as docs/evidence/stage2-coingecko-bridge-evidence.csv. Unique current pair bridges are independent mapping evidence; alias semantics remain UNVERIFIED until raw-news matching rules are defined and validated.
