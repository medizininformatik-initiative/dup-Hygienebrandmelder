# Hygienebrandmelder: FHIR Data Extraction

## Project Description
The [**Hygienebrandmelder**](https://forschen-fuer-gesundheit.de/fdpgx-project/der-hygienebrandmelder-ein-proaktives-und-lernendes-system-fuer-die-infektionspraevention/) project aims to establish a proactive and learning system for infection prevention. By analyzing historical and structural hospital data, the project seeks to identify, monitor, and prevent nosocomial (hospital-acquired) infections at an early stage. 

This repository contains an R-based extraction script used to securely pull the required clinical and demographic data from a local FHIR server. The data (by default covering 2009 to 2025 as we were provided that period from the DIZ in Regensburg) are required to train machine learning models for the infection prevention system.

For any questions feel free to contact us under the following MII ZULIP channel: [#DUP-Hygienebrandmelder](https://mii.zulipchat.com/#narrow/channel/560831-DUP-Hygienebrandmelder/topic//with/585614543).

## Responsibility
- **Project Lead:** *PD Dr. Bärbel Kieninger* (Hygienebrandmelder Team)
- **Original Script Author:** *Clara Fischer* (DIZ Regensburg)
- **Script Updated and README provided by:** *Gregor Donabauer* (Hygienebrandmelder Team)

## Prerequisites
- **Environment:** An active R installation (RStudio or CLI).
- **R Packages:** `fhircrackr`, `data.table`, and `httr`. *(Note: The script features smart package loading and will automatically install required packages only if they are missing. Interactive password entry additionally installs `getPass` on demand).*
- **FHIR Endpoint:** A reachable FHIR server URL.
- **Authentication Credentials:** A valid technical user account for the FHIR server.
- **Security & Network Considerations**: Before executing the script, please check the "Security & Network Considerations" section at the end of this README for SSL configuration details.

## Configuration
The script has been designed for maximum ease of use. You do not need to search through the code to modify parameters. Simply open the `HBM.R` file and adjust the `CONFIG` list at the very top:

```R
CONFIG <- list(
  base_url      = "https://your-fhir-server.de/fhir/", # Your FHIR base URL
  auth_user     = "technical_user",                    # Your technical user
  verify_ssl    = FALSE,                               # Set TRUE for strict SSL 
  ssl_cert_path = "certificate.crt",                   # Path to cert (if verify_ssl = TRUE)
  start_year    = 2009,                                # Extraction start
  end_year      = 2025,                                # Extraction end
  chunk_patient   = 50,                                # Pagination chunks
  chunk_condition = 80,
  chunk_procedure = 100,
  file_encounter  = "encounter.csv",                   # Output filenames
  file_patient    = "patient.csv",
  file_condition  = "condition.csv",
  file_procedure  = "procedure.csv"
)
```

## Execution Information

The script supports three password input methods. For non-interactive automation, prefer the `HBM_FHIR_PASSWORD` environment variable because it avoids shell history and process-list exposure. A CLI argument is still supported as a fallback, and interactive runs use a hidden prompt.

### Option 1: Environment Variable (Recommended)

```bash
HBM_FHIR_PASSWORD='YOUR_SECURE_PASSWORD' Rscript HBM.R
```

### Option 2: Command Line Argument (Fallback)

```bash
Rscript HBM.R "YOUR_SECURE_PASSWORD"
```

### Option 3: Interactive Session (RStudio / R Console)

```
Enter FHIR Auth Password:
```

## Data Extracted

The script iterates through FHIR resources, flattens them using `fhircrackr`, and exports them as four relational CSV files. Dates are strictly formatted to `%d-%m-%Y`.

1. **Encounter (`encounter.csv`)**

   - **Scope:** Inpatient encounters (class=IMP), pulled quarterly for the configured years.

   - **Extracted Fields:** `encounter_id`, `kontaktklasse`, `kontaktebene`, `patient_id`, `aufnahmenummer`, `aufnahmeanlass`, `beginndatum`, `enddatum`, `fachabteilung`.

2. **Patient (`patient.csv`)**

   - **Scope:** Patients associated with the extracted encounters.

   - **Extracted Fields:** `patient_id`, `gender`, `birth_date`.

3. **Condition (`condition.csv`)**

   - **Scope:** Diagnoses (ICD codes) for the extracted patients.

   - **Extracted Fields:** `condition_id`, `patient_id`, `icd_code`, `recordedDate`.

4. **Procedure (`procedure.csv`)**

   - **Scope:** Medical procedures for the extracted patients.

   - **Extracted Fields:** `procedure_id`, `patient_id`, `prozedur_code`, `datum`.

## Core Features & Technical Details

   - **Centralized Configuration:** All variables (URLs, batch sizes, filenames) are grouped at the top for easy maintenance.

   - **Smart Package Management:** Prevents redundant downloads by checking your local library before invoking `install.packages()`.

   - **API Pagination & Chunking:** To avoid overloading the FHIR server, encounters are split into temporal quarters. Subsequent resources are batched into chunks using standard string concatenation.

   - **Interruption Resilience (Restartability):** If the script fails or is stopped manually, re-running it will cross-check the existing IDs in the CSVs and append only new data. This prevents duplicate rows and saves massive amounts of runtime.

   - **Global Deduplication:** Internal logic ensures that duplicate FHIR IDs in the same chunk and globally across iterations are dropped before writing to disk.

##  <a name="security"></a>Security & Network Considerations

   - **SSL Verification Toggle:** By default, `CONFIG$verify_ssl` is set to `FALSE` to bypass strict SSL verification (for internal hospital networks with self-signed certificates).

   - **Production Environments:** For secure deployments, change `verify_ssl = TRUE` in the CONFIG and ensure ssl_cert_path points to a valid `.crt` or `.pem` file. The script will automatically route the certificate to the underlying HTTP configuration.