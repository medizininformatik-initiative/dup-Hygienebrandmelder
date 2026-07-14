# ---------------------------------------------------
# Datenextraktion für das Projekt Hygienebrandmelder
# ---------------------------------------------------

# ==============================================================================
# 1. CONFIGURATION BLOCK
# ==============================================================================
# Adjust the values in this list to configure the script for your environment.

CONFIG <- list(
  # --- Server & Authentication ---
  base_url      = "https://your-fhir-server.de/fhir/", # REQUIRED: Base URL of the FHIR Server
  auth_user     = "technical_user",                    # REQUIRED: Username

  # --- SSL/TLS Settings ---
  verify_ssl    = FALSE,                               # Set to TRUE for secure production environments
  ssl_cert_path = "certificate.crt",                   # Used only if verify_ssl = TRUE

  # --- Extraction Scope ---
  start_year    = 2009,
  end_year      = 2025,

  # --- Performance & Pagination (Chunk Sizes) ---
  chunk_patient   = 50,
  chunk_condition = 80,
  chunk_procedure = 100,

  # --- Output File Names ---
  file_encounter  = "encounter.csv",
  file_patient    = "patient.csv",
  file_condition  = "condition.csv",
  file_procedure  = "procedure.csv"
)
# ==============================================================================


# ==============================================================================
# 2. SETUP & INITIALIZATION
# ==============================================================================

# Smart Package Installation (only installs if missing)
required_packages <- c("fhircrackr", "data.table", "httr")
new_packages <- required_packages[!(required_packages %in% installed.packages()[,"Package"])]
if(length(new_packages)) install.packages(new_packages)

library(fhircrackr)
library(data.table)

# Password Handling (preferred: env var, fallback: CLI arg, interactive: hidden prompt)
args <- commandArgs(trailingOnly = TRUE)
auth_pw <- Sys.getenv("HBM_FHIR_PASSWORD", unset = "")
if (nzchar(auth_pw)) {
  # preferred for automation; avoids shell history/process listings
} else if (length(args) > 0 && nzchar(args[1])) {
  auth_pw <- args[1]
} else if (interactive()) {
  if (!requireNamespace("getPass", quietly = TRUE)) install.packages("getPass")
  auth_pw <- getPass::getPass("Enter FHIR Auth Password: ")
} else {
  stop("Password missing! Set HBM_FHIR_PASSWORD or provide it as the first argument to HBM.R.")
}

# SSL Configuration
if (!CONFIG$verify_ssl) {
  httr::set_config(httr::config(ssl_verifypeer = 0L, ssl_verifyhost = 0L))
} else if (file.exists(CONFIG$ssl_cert_path)) {
  httr::set_config(httr::config(cainfo = CONFIG$ssl_cert_path))
} else {
  warning("SSL verification is enabled, but certificate file was not found.")
}


# ==============================================================================
# 3. FHIR DESIGNS
# ==============================================================================

encounter_design <- fhir_table_description(
  resource = "Encounter",
  cols = c(
    encounter_id   = "id",
    kontaktklasse  = "class/code",
    kontaktebene   = "type/coding/code",
    patient_id     = "subject/reference",
    aufnahmenummer = "identifier/value",
    aufnahmeanlass = "hospitalization/admitSource/coding/code",
    beginndatum    = "period/start",
    enddatum       = "period/end",
    fachabteilung  = "serviceType/coding/code"
  )
)

patient_design <- fhir_table_description(
  resource = "Patient",
  cols = c(
    patient_id  = "id",
    gender      = "gender",
    birth_date  = "birthDate"
  )
)

condition_design <- fhir_table_description(
  resource = "Condition",
  cols = c(
    condition_id        = "id",
    patient_id          = "subject/reference",
    icd_code            = "code/coding/code",
    recordedDate        = "recordedDate"
  )
)

procedure_design <- fhir_table_description(
  resource = "Procedure",
  cols = c(
    procedure_id   = "id",
    patient_id     = "subject/reference",
    prozedur_code  = "code/coding/code",
    datum          = "performedDateTime"
  )
)


# ==============================================================================
# 4. ENCOUNTER EXTRACTION (Quarterly)
# ==============================================================================

all_patient_ids <- character()
first_write_encounter <- !file.exists(CONFIG$file_encounter)

cat("Starting Encounter extraction...\n")

for(year in CONFIG$start_year:CONFIG$end_year){
  quarters <- list(
    c(as.Date(paste0(year,"-01-01")), as.Date(paste0(year,"-03-31"))),
    c(as.Date(paste0(year,"-04-01")), as.Date(paste0(year,"-06-30"))),
    c(as.Date(paste0(year,"-07-01")), as.Date(paste0(year,"-09-30"))),
    c(as.Date(paste0(year,"-10-01")), as.Date(paste0(year,"-12-31")))
  )

  for(q in quarters){
    enc_url <- paste0(CONFIG$base_url, "Encounter?",
                      "date=ge", q[1],
                      "&date=lt", q[2] + 1,
                      "&class=IMP&_count=200")

    bundles <- fhir_search(request = enc_url, username = CONFIG$auth_user,
                           password = auth_pw, max_bundles = Inf)

    if(length(bundles) > 0){
      df_enc <- fhir_crack(bundles, design=encounter_design)

      if(nrow(df_enc) > 0){
        df_enc$beginndatum <- format(as.Date(df_enc$beginndatum), "%d-%m-%Y")
        df_enc$enddatum    <- format(as.Date(df_enc$enddatum), "%d-%m-%Y")

        # Deduplicate Encounters
        if(file.exists(CONFIG$file_encounter)){
          dt_existing <- fread(CONFIG$file_encounter, select="encounter_id")
          new_enc <- df_enc[!df_enc$encounter_id %in% dt_existing$encounter_id,]
        } else {
          new_enc <- df_enc
        }

        if(nrow(new_enc) > 0){
          all_patient_ids <- c(all_patient_ids, new_enc$patient_id)
          write.table(new_enc, CONFIG$file_encounter, sep=",",
                      row.names=FALSE,
                      col.names=first_write_encounter,
                      append=!first_write_encounter)
          first_write_encounter <- FALSE
        }
      }
    }
  }
}


# ==============================================================================
# 5. PATIENT EXTRACTION
# ==============================================================================

cat("Starting Patient extraction...\n")

patient_ids <- unique(sub("Patient/", "", all_patient_ids))
split_ids <- split(patient_ids, ceiling(seq_along(patient_ids)/CONFIG$chunk_patient))
first_write_patient <- !file.exists(CONFIG$file_patient)

for (id_chunk in split_ids) {
  patient_request <- fhir_url(
    url = CONFIG$base_url,
    resource = "Patient",
    parameters = list(`_id` = paste(id_chunk, collapse = ","))
  )

  patient_bundles <- fhir_search(request = patient_request, username = CONFIG$auth_user,
                                 password = auth_pw, max_bundles = Inf)

  if (length(patient_bundles) > 0) {
    df_pat <- fhir_crack(patient_bundles, design = patient_design)

    if (nrow(df_pat) > 0) {
      df_pat <- df_pat[!duplicated(df_pat$patient_id), ]

      if (file.exists(CONFIG$file_patient)) {
        existing_ids <- fread(CONFIG$file_patient, select = "patient_id")
        df_pat <- df_pat[!df_pat$patient_id %in% existing_ids$patient_id, ]
      }

      if (nrow(df_pat) > 0) {
        write.table(df_pat, CONFIG$file_patient, sep = ",",
                    row.names = FALSE,
                    col.names = first_write_patient,
                    append = !first_write_patient)
        first_write_patient <- FALSE
      }
    }
  }
}


# ==============================================================================
# 6. CONDITION EXTRACTION
# ==============================================================================

cat("Starting Condition extraction...\n")

split_ids_cond <- split(patient_ids, ceiling(seq_along(patient_ids)/CONFIG$chunk_condition))
first_write_condition <- !file.exists(CONFIG$file_condition)

for(id_chunk in split_ids_cond){
  condition_request <- fhir_url(
    url = CONFIG$base_url,
    resource = "Condition",
    parameters = list(`subject` = paste(id_chunk, collapse = ","))
  )

  condition_bundles <- fhir_search(request = condition_request, username = CONFIG$auth_user,
                                   password = auth_pw,  max_bundles = Inf)

  if(length(condition_bundles) > 0){
    df_cond <- fhir_crack(condition_bundles, design = condition_design)

    if(nrow(df_cond) > 0){
      df_cond <- df_cond[!duplicated(df_cond$condition_id), ]
      df_cond$recordedDate <- format(as.Date(df_cond$recordedDate), "%d-%m-%Y")

      if (file.exists(CONFIG$file_condition)) {
        existing_ids <- fread(CONFIG$file_condition, select = "condition_id")
        df_cond <- df_cond[!df_cond$condition_id %in% existing_ids$condition_id, ]
      }

      if (nrow(df_cond) > 0) {
        write.table(df_cond, CONFIG$file_condition, sep = ",",
                    row.names = FALSE,
                    col.names = first_write_condition,
                    append = !first_write_condition)
        first_write_condition <- FALSE
      }
    }
  }
}


# ==============================================================================
# 7. PROCEDURE EXTRACTION
# ==============================================================================

cat("Starting Procedure extraction...\n")

split_ids_proc <- split(patient_ids, ceiling(seq_along(patient_ids)/CONFIG$chunk_procedure))
first_write_procedure <- !file.exists(CONFIG$file_procedure)
seen_procedure_ids <- if (file.exists(CONFIG$file_procedure)) {
  fread(CONFIG$file_procedure, select = "procedure_id")$procedure_id
} else {
  character()
}

for(id_chunk in split_ids_proc){
  procedure_request <- fhir_url(
    url = CONFIG$base_url,
    resource = "Procedure",
    parameters = list(`subject` = paste(id_chunk, collapse = ","))
  )

  procedure_bundles <- fhir_search(request = procedure_request, username = CONFIG$auth_user,
                                   password = auth_pw, max_bundles = Inf)

  if(length(procedure_bundles) > 0){
    df_pro <- fhir_crack(procedure_bundles, design = procedure_design)

    if(nrow(df_pro) > 0){
      df_pro <- df_pro[!duplicated(df_pro$procedure_id), ]
      df_pro <- df_pro[!df_pro$procedure_id %in% seen_procedure_ids, ]
      seen_procedure_ids <- c(seen_procedure_ids, df_pro$procedure_id)

      if(nrow(df_pro) > 0){
        df_pro$datum <- format(as.Date(df_pro$datum), "%d-%m-%Y")
        fwrite(df_pro, CONFIG$file_procedure, append = !first_write_procedure)
        first_write_procedure <- FALSE
      }
    }
  }
}

cat("Extraction complete!\n")