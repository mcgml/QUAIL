# Packages
suppressMessages(require(data.table))
suppressMessages(require(quantreg))
suppressMessages(require(parallel))
suppressMessages(library(optparse))
suppressMessages(library(BEDMatrix))


options(stringsAsFactors = F)
option_list = list(
  make_option("--pheno_rs", action = "store", default = NA, type = "character", help = "The path of the phenotype rank score file"),
  make_option("--geno", action = "store", default = NA, type = "character", help = "The path of the genotype file"),
  make_option("--covar", action = "store", default = NA, type = "character", help = "The path of the covariate file"),
  make_option("--output", action = "store", default = NA, type = "character", help = "The path of the output file"),
  make_option("--num_cores", action = "store", default = NA, type = "integer", help = "Numbers of cores for parellel computing"),
  make_option("--start", action = "store", default = NA, type = "integer", help = "Index of SNP that starts computing."),
  make_option("--end", action = "store", default = NA, type = "integer", help = "Index of SNP that ends computing.")
)

opt = parse_args(OptionParser(option_list=option_list))

cat("********************************************************************* \n")
cat("* Quantile integral linear model (QUAIL) \n")
cat("* Version 1.0.0 \n")
cat("* Genome-wide vQTL analysis \n")
cat("* Step2: Performing genome-wide vQTL analysis \n")
cat("* (C) Jiacheng Miao \n")
cat("* University of Wisconsin–Madison \n")
cat("* https://github.com/qlu-lab/QUAIL \n")
cat("* GNU General Public License v3 \n")
cat("********************************************************************* \n \n")

# --- 0. I/O check
if (is.na(opt$pheno_rs) | is.na(opt$geno) |  is.na(opt$covar) | is.na(opt$output) | is.na(opt$num_cores)) {
    cat("ERROR: Missing essential inputs.\n")
    q("no")
}

cat("Options in effect: \n")
cat("Rscript LOGODetect.R \\ \n")
cat(paste0("--pheno_rs ", opt$pheno_rs, " \\ \n"))
cat(paste0("--geno ", opt$geno, " \\ \n"))
cat(paste0("--covar ", opt$covar, " \\ \n"))
cat(paste0("--output", opt$output, " \\ \n"))
cat(paste0("--num_cores ", opt$num_cores, " \\ \n"))

# Input parameters
pheno_rank_score <- opt$pheno_rs
genotype <- opt$geno
covariate <- opt$covar
output <- opt$output
num_cores <- opt$num_cores
snp_start <- opt$start
snp_end <- opt$end


geno_bed <- suppressMessages(BEDMatrix((paste0(genotype, ".bed"))))
geno_bim <- fread(paste0(genotype, ".bim"))

if(is.na(opt$start) | is.na(opt$end)){
    snp_start <- 1
    snp_end <- nrow(geno_bim)
    cat("No index of SNP that starts or ends computing.\nQUAIL will fit Genome-wide vQTL analysis for all SNPs.\n")
}


cat("Preparing the data:\n")
pheno <- as.data.frame(fread(pheno_rank_score, stringsAsFactors = F))
covar <- as.data.frame(fread(covariate, data.table = F, stringsAsFactors = F))

# align the  phenotype, covaraite, genotype files
IID <- gsub(pattern = paste0(".*_(.*)"), rownames(geno_bed), replacement = "\\1")
IID_overlap <- intersect(pheno$IID, IID)
IID_overlap <- intersect(covar$IID, IID_overlap)
index_pheno <- match(IID_overlap, pheno$IID)
index_covar <- match(IID_overlap, covar$IID)
index_geno <- match(IID_overlap, IID)
pheno_lm <- pheno[index_pheno, ]
covar_lm <- as.data.frame(covar[index_covar, 3:ncol(covar)])

# Progress bar of the mclapply; Source: https://stackoverflow.com/questions/10984556/is-there-way-to-track-progress-on-a-mclapply/26892969#26892969
mclapply2 <- function(X, FUN, ..., 
    mc.preschedule = TRUE, mc.set.seed = TRUE,
    mc.silent = FALSE, mc.cores = getOption("mc.cores", 2L),
    mc.cleanup = TRUE, mc.allow.recursive = TRUE,
    mc.progress=TRUE, mc.style=3) {
    if (!is.vector(X) || is.object(X)) X <- as.list(X)

    if (mc.progress) {
        f <- fifo(tempfile(), open="w+b", blocking=T)
        p <- parallel:::mcfork()
        pb <- txtProgressBar(0, length(X), style=mc.style)
        setTxtProgressBar(pb, 0) 
        progress <- 0
        if (inherits(p, "masterProcess")) {
            while (progress < length(X)) {
                readBin(f, "double")
                progress <- progress + 1
                setTxtProgressBar(pb, progress) 
            }
            cat("\n")
            parallel:::mcexit()
        }
    }
    tryCatch({
        result <- mclapply(X, function(...) {
                res <- FUN(...)
                if (mc.progress) writeBin(1, f)
                res
            }, 
            mc.preschedule = mc.preschedule, mc.set.seed = mc.set.seed,
            mc.silent = mc.silent, mc.cores = mc.cores,
            mc.cleanup = mc.cleanup, mc.allow.recursive = mc.allow.recursive
        )

    }, finally = {
        if (mc.progress) close(f)
    })
    result
}

# QUAIL function 
QUAIL <- function(i){
    # Obtain the SNP information
    SNP <- geno_bed[index_geno, i]
    snp_name <- geno_bim$V2[i]
    chr <- geno_bim$V1[i]
    bp <- geno_bim$V4[i]
    a1 <- geno_bim$V5[i]
    a2 <- geno_bim$V6[i]

    ## Keep the non-NA in SNP
    index_non_NA <- which(!is.na(SNP))
    SNP <- SNP[index_non_NA]
    covar_lm_non_NA <- as.data.frame(covar_lm[index_non_NA, ])

    # Calculate MAF
    maf <- sqrt(sum(SNP == 2, na.rm=T)/sum(!is.na(SNP)))

    # Standardized the SNP
    SNP <- scale(SNP)

    # Obtain the G_star
    m_SNP_covar <- lm(SNP ~ ., data = covar_lm_non_NA)
    G_star <- m_SNP_covar$residual

    # Run regression between Y_QI and G_star
    Y_QI <- sqrt(length(SNP))*pheno_lm[, 3]
    Y_QI <- Y_QI[index_non_NA]
    coeff <- summary(lm(Y_QI ~ G_star))$coefficients
    QUAIL_results <- c(chr, snp_name, bp, a1, a2, maf, coeff[2, c(1, 2, 4)], length(Y_QI))
    return(QUAIL_results)
}


# Parallel of QUAIL
Fit_QUAIL <- function(start = snp_start, end = snp_end){
    df_out <- mclapply2(start:end, QUAIL, mc.cores = num_cores)
    df_out <- do.call(rbind, df_out)
    df_out <- as.data.frame(df_out)
    colnames(df_out) <-  c('CHR', 'SNP', 'BP', 'A1', 'A2', 'FREQ', 'BETA','SE','P', 'N')
    # string to num
    df_out$BP <- as.numeric(df_out$BP)
    df_out$FREQ <- as.numeric(df_out$FREQ)
    df_out$BETA <- as.numeric(df_out$BETA)
    df_out$SE <- as.numeric(df_out$SE)
    df_out$P <- as.numeric(df_out$P)
    df_out$N <- as.numeric(df_out$N)
    # convect standardized beta into allele beta; also SE
    df_out$BETA <- df_out$BETA/(sqrt(2*df_out$FREQ*(1-df_out$FREQ)))
    df_out$SE <- df_out$SE/(sqrt(2*df_out$FREQ*(1-df_out$FREQ)))
    return(df_out)
}

cat("Begin running Genome-wide vQTL analysis:\n")

# To suppress some Warnings that are harmless: https://github.com/HenrikBengtsson/future/issues/218
df_all_snp <- suppressWarnings(Fit_QUAIL(start=snp_start, end =snp_end))

# Write out the results
cat("Write out the summary statistics.\n")
fwrite(df_all_snp, output, col.names = T, row.names = F, quote = F, sep = "\t", na = "NA")
cat("Finish!\n")
