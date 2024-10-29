#!/bin/bash

# This script is the first version of NanoASV
# Authors : Arthur Cousson, Frederic Mahe
# 08/03/2023
#***************************************************************************************************************************
# Unset non-essential variables to deal with singularity eating local env variables
unset $(env | grep -vE '^(HOME|USER$|PWD|TMP|LANG|LC_)' | cut -d= -f1)
# Unset all BASH_FUNC_* variables
for func in $(env | grep -o '^BASH_FUNC_.*=' | sed 's/=$//') ; do
    unset "$func" 2> /dev/null
done
# Set essential variables explicitly
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LD_LIBRARY_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

#***************************************************************************************************************************

START=$(date +%s) #Set the clock for timer

#/usr/games/cowsay -TU NanoASV is a workflow created by Arthur Cousson with useful contributions from Frederic Mahe and Enrique Ortega-Abbud. Hope this will help you analyse your data. && /usr/games/cowsay -f dragon Death To Epi2Me !
#echo "NanoASV is a workflow created by Arthur Cousson with useful contributions from Frederic Mahe and Enrique Ortega-Abbud. Don't forget to cite NanoASV and its dependencies if it helps you treating your sequencing data." #&& /usr/games/cowsay -f dragon Death To Epi2Me !

#Log system and error handling *********************************************************************************************
# LOG_FILE="NanoASV_log.txt"
# exec > >(tee -a $LOG_FILE) 2>&1
set -e
#***************************************************************************************************************************


#***************************************************************************************************************************
# Read the arguments passed to the script
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -d|--dir)
            DIR="$2"
            shift
            shift
            ;;
        -o|--out)
            OUT="$2"
            shift
            shift
            ;;
        -q|--quality)
            QUAL="$2"
            shift
            shift
            ;;
        -l|--minlength)
            MINL="$2"
            shift
            shift
            ;;
        -L|--maxlength)
            MAXL="$2"
            shift
            shift
            ;;
        -i|--id-vsearch)
            ID="$2"
            shift
            shift
            ;;
        -ab|--minab)
            MINAB="$2"
            shift
            shift
            ;;
        -p|--num-process)
            NUM_PROCESSES="$2"
            shift
            shift
            ;;
        -db|--database)
            DATABASE="$2"
            shift
            shift
            ;;
        --no-r-cleaning)
            R_CLEANING=0
            shift
            ;;
        --subsampling)
            SUBSAMPLING="$2"
            shift
            shift
            ;;
        --notree)
            TREE=0
            shift
            ;;
        --docker)
            DOCKER=1
            shift
            ;;
        --ronly)
            R_STEP_ONLY=1
            shift
            ;;
        -v|--version)
            echo "NanoASV 1.0 - https://github.com/ImagoXV/NanoASV - Arthur Cousson and Frederic Mahe"
            exit
            shift
            ;;
        -h|--help)
            cat /help.txt
            exit
            shift
            ;;
        --metadata)
            METADATA="$2"
            shift
            shift
            ;;
        --requirements)
            cat requirements.txt
            exit
            shift
            ;;
        *)
            echo "Unknown option: $1"
            cat /help.txt
            exit 1
            shift
            ;;
    esac
done

#***************************************************************************************************************************
# Manual entries - Arguments
# Set default values
DEFAULT_QUAL=8
DEFAULT_MINL=1300
DEFAULT_MAXL=1700
DEFAULT_ID=0.7
DEFAULT_NUM_PROCESSES=1
DEFAULT_R_CLEANING=1
DEFAULT_MINAB=5
DEFAULT_SUBSAMPLING=50000
DEFAULT_TREE=1
DEFAULT_DOCKER=0
DEFAULT_R_STEP_ONLY=0
DEFAULT_METADATA=${DIR}
DEFAULT_DATABASE="/database/SILVA_138.1_SSURef_tax_silva.fasta.gz"
#***************************************************************************************************************************
# Assign default values if variables are empty
#DIR="/data"
QUAL="${QUAL:-$DEFAULT_QUAL}"
MINL="${MINL:-$DEFAULT_MINL}"
MAXL="${MAXL:-$DEFAULT_MAXL}"
ID="${ID:-$DEFAULT_ID}"
NUM_PROCESSES="${NUM_PROCESSES:-$DEFAULT_NUM_PROCESSES}"
R_CLEANING="${R_CLEANING:-$DEFAULT_R_CLEANING}"
SUBSAMPLING="${SUBSAMPLING:-$DEFAULT_SUBSAMPLING}"
TREE="${TREE:-$DEFAULT_TREE}"
DOCKER="${DOCKER:-$DEFAULT_DOCKER}"
SUBSAMPLING=$((SUBSAMPLING * 4))
R_STEP_ONLY="${R_STEP_ONLY:-$DEFAULT_R_STEP_ONLY}"
METADATA="${METADATA:-$DEFAULT_METADATA}"
MINAB="${MINAB:-$DEFAULT_MINAB}"


if [ -z "$DATABASE" ]; then
    echo "No personal database path specified. Using Silva 138.1"
    DATABASE="${DATABASE:-$DEFAULT_DATABASE}"
fi

#***************************************************************************************************************************

#***************************************************************************************************************************
# Check if the required binaries are correctly installed
for BINARY in mafft chopper porechop minimap2 samtools FastTree Rscript ; do
    /bin/which ${BINARY} > /dev/null || \
        { echo "${BINARY} is not there. Please reinstall" ; exit 1 ; }
done


#***************************************************************************************************************************
# Check if DIR is empty and no default value is provided
if [[ -z $DIR ]]; then
    /usr/games/cowsay -d "Error: -d needs an argument, I don't know where your sequences are." >&2
    exit 1
fi
# Check if OUT is empty and no default value is provided
if [[ -z $OUT ]]; then
    /usr/games/cowsay -d "Error: -o needs an argument. You don't want me to print to stdout" >&2
    exit 1
fi

#Metadata sanity checks **********************************************
(cd "${METADATA}"
 #Check if metadata.csv has been provided by the user
 [[ -s metadata.csv ]] || \
     { /usr/games/cowsay -d "Error : Please provide a metadata.csv" >&2 ; exit 1 ; }

 #Check if metadata is indeed a csv and has at least 3 columns (1 rownames, two data)
 awk -F "," 'NR == 1 { exit NF > 2 ? 0 : 1}' metadata.csv || \
     { echo "ERROR: Check metadata.csv: it does not look like a csv file. Are you sure you are using coma to separate the fields? Do you have more than two columns?" ; exit 1 ; }

 #Check if metadata.csv rownames structure is correct
 awk -F "," 'NR == 1 { exit $1 == "" ? 0 : 1}' metadata.csv || \
     { echo "ERROR: First field of first line should be empty. Please check metadata.csv file structure." ; exit 1 ; }

 #Check if metadata.csv contains enough lines
 awk 'END{ exit NR > 1 ? 0 : 1}' metadata.csv || \
     { echo "ERROR: metadata.csv: Missing header and/or data information. Too few lines." ; exit 1 ; }


 # Check if metadata barcodes are found within DIR
 cut -f1 -d "," metadata.csv | \
     tail -n +2 | \
     while read sample_name ; do
         [[ -d ${sample_name} ]] || \
             { echo "ERROR, ${sample_name} not found. Please check metadata.csv and barcodes directories" ; exit 1 ; }
     done

 #Check if number of fields is consistent is consistent accross all number of lines
 awk -F "," '{print NF}' metadata.csv | \
     sort -u | \
     awk 'END {exit NR == 1 ? 0 : 1}' || \
     { echo ERROR: Check metadata.csv: not all the lines have the same number of columns ; }
)

## Create temporary directory ***********************************************************************************************
# date
# echo Creating temporary directory at /tmp/
TMP="$(mktemp --directory || exit 1)"

#****************************************************************************************************************************
if [[ "${DOCKER}" -eq 1 ]]; then #Check for Docker's way to navigate through files
    OUTPWD="${DIR}/${OUT}"
else
    OUTPWD="$(pwd)/${OUT}"
fi

mkdir --parents \
      "${OUTPWD}"/Results/{ASV,Tax,Unknown_clusters,Phylogeny,Exact_affiliations,Rdata,CSV} 2> /dev/null

#***************************************************************************************************************************
# Check if DATABASE is empty and no default value is provided **************************************************************
# if [[ -z $DATABASE ]]; then
#     read -p "No database specified. Do you wish to download SILVA 138.1? (y/n): " response
#     if [[ "$response" == "y" ]]; then
#         echo "Downloading database..."
#         if ! wget -P "${OUTPWD}/SILVA/" https://www.arb-silva.de/fileadmin/silva_databases/release_138_1/Exports/SILVA_138.1_SSURef_tax_silva.fasta.gz; then
#         echo "Error: Failed to download the database."
#         exit 1
#         fi
#         DATABASE="${OUTPWD}/SILVA/SILVA_138.1_SSURef_tax_silva.fasta.gz"
#     else
#         echo "You need to specify a database. Please insure your reference database matches NanoASV requirements. Run nanoasv --requirements for more informations"
#         exit 1
#     fi
# else
#     echo "Using provided database: $DATABASE"
# fi

#R Step Only if problem *********************************************************************************************
if [ "$R_STEP_ONLY" -eq 1 ]; then
    ##Production of phyloseq object *************************************************************************************
    echo "Launching Ronly option"
    Rscript /script.r "${DIR}" "${OUTPWD}" "${R_CLEANING}" "${TREE}" "${METADATA}" 2> /dev/null

    #********************************************************************************************************************
    declare -i TIME=$(date +%s)-$START
    #********************************************************************************************************************
    echo "Data treatment is over."
    echo "NanoASV Rstep took $TIME seconds to perform."
    echo "Don't forget to cite NanoASV and its dependencies if it helps you treating your sequencing data."
    #********************************************************************************************************************
    exit
fi

#Database indexing *********************************************************************************************
DATABASE_DIR=$(dirname "$DATABASE")
DATABASE_NAME=$(basename "$DATABASE" .mmi)


if [[ -f "$DATABASE.mmi" ]]; then
    echo "Minimap2 index is present in the directory: $DATABASE_DIR, using $DATABASE_NAME as database"
    IDX="$DATABASE.mmi"
    awk '/^>/ {printf("%s%s\n",(NR==1)?"":RS,$0);next;} {printf("%s",$0);} END {printf("\n");}' "$DATABASE" > $TMP/SINGLELINE_database.fasta
    grep "^>" $TMP/SINGLELINE_database.fasta | tr -d ">" > $TMP/TAXONOMY_${DATABASE_NAME}
else
    echo "Minimap2 index is missing in the directory: $DATABASE_DIR : Indexing"
    if [[ "${DOCKER}" -eq 1 ]]; then
        minimap2 -x map-ont -d "$DATABASE.mmi" "$DATABASE" 2> /dev/null
        #ls -alh $DATABASE_DIR
        IDX="$DATABASE.mmi"
        #echo $IDX
    else
        minimap2 -x map-ont -d "$TMP/$DATABASE_NAME.mmi" "$DATABASE" 2> /dev/null
        #ls -alh $TMP
        IDX="$TMP/$DATABASE_NAME.mmi"
        #echo $IDX
    fi
    #Modification, to avoid altering user database file
    echo "Preparing taxonomy from fasta file. Are you sure your database fits NanoASV requirements ?"
    if file "$DATABASE" | grep -q 'gzip compressed'; then
        zcat "$DATABASE" | awk '/^>/ {printf("%s%s\n",(NR==1)?"":RS,$0);next;} {printf("%s",$0);} END {printf("\n");}' > $TMP/SINGLELINE_database.fasta
        grep "^>" $TMP/SINGLELINE_database.fasta | tr -d ">" > $TMP/TAXONOMY_${DATABASE_NAME}
    else
        awk '/^>/ {printf("%s%s\n",(NR==1)?"":RS,$0);next;} {printf("%s",$0);} END {printf("\n");}' "$DATABASE" > $TMP/SINGLELINE_database.fasta
        grep "^>" $TMP/SINGLELINE_database.fasta | tr -d ">" > $TMP/TAXONOMY_${DATABASE_NAME}
    fi
fi

TAX="${TMP}/TAXONOMY_${DATABASE_NAME}"


## Concatenation of fastq files *********************************************************************************************

cat_files() {
    BARCODE_DIR="$1"
    # Extract the barcode from the directory name
    BARCODE=$(basename "${BARCODE_DIR}")
    # Concatenate all fastq.gz files in the barcode directory
    zcat "${DIR}/${BARCODE_DIR}"/*.fastq.gz | gzip > "${TMP}/${BARCODE}.fastq.gz"
}

export -f cat_files  # Export the function so that it can be used in parallel

echo "Step 1/9 : Concatenation"
find "${DIR}" -maxdepth 1 -type d -name "barcode*" | env TMP="${TMP}" QUAL="${QUAL}" MINL="${MINL}" MAXL="${MAXL}" ID="${ID}" \
                                                         parallel -j "${NUM_PROCESSES}" cat_files

#***************************************************************************************************************************

## Define function to filter files******************************************************************************************

filter_file() {
    (
        filename=$(basename "$1")
        output_file="FILTERED_$filename"
        zcat "$1" | chopper -q "${QUAL}" -l "${MINL}" --maxlength "${MAXL}" 2> /dev/null | gzip > "${TMP}/${output_file}"
    )
}

export -f filter_file

#***************************************************************************************************************************


## Filtering sequences based on quality with Chopper **********************************************************************

# Iterate over the files in parallel
echo "Step 2/9 : Filtering with Chopper"
find "${TMP}" -maxdepth 1 -name "barcode*.fastq.gz" | env TMP="${TMP}" QUAL="${QUAL}" MINL="${MINL}" MAXL="${MAXL}" ID="${ID}"\
                                                          parallel -j "${NUM_PROCESSES}" filter_file
#echo Unfiltered files are being deleted
rm ${TMP}/barcode*.fastq.gz

# #***************************************************************************************************************************


## Trim adapaters with Porechop ********************************************************************************************
#echo "Porechop step"

chop_file() {
    (
        #echo "Concerned file is $1"
        filename=$(basename "$1")
        output_file="CHOPED_$filename"
        porechop --verbosity 0 -i $1 -o ${TMP}/${output_file}
        #echo "$1 choped"
    )
}

export -f chop_file
#***************************************************************************************************************************

echo "Step 3/9 : Adapter trimming with Porechop"
# Iterate over the files in parallel
find "${TMP}" -maxdepth 1 -name "FILTERED*.fastq.gz" | env TMP="${TMP}" QUAL="${QUAL}" MINL="${MINL}" MAXL="${MAXL}" \
                                                           ID="${ID}"  parallel -j "${NUM_PROCESSES}" chop_file

#echo Filtered datasets are being deleted
#rm ${TMP}/NONCHIM*
rm ${TMP}/FILTERED*

# Subsampling
echo "Step 4/9 : Subsampling"
(cd ${TMP}
 for CHOPED_FILE in CHOPED*.fastq.gz ; do
     zcat "${CHOPED_FILE}" | head -n "${SUBSAMPLING}"  > "SUB_${CHOPED_FILE}"
     #echo ${CHOPED_FILE} sub-sampled
 done
)

#echo Full size datasets are being deleted
rm ${TMP}/CHOPED*
#***************************************************************************************************************************
# # The following is inactivated because we first need to cluster all sequences together to find chimeras. We need to try new vsearch algorithm.
# ## Chimera detection *******************************************************************************************************
# # Chimera detection function definition
# chimera_detection() {
#   (
#   #echo Chimera detection step
#   filename=$(basename "$1")
#   chimera_out="NONCHIM_$filename"
#   vsearch --uchime_denovo $1 --nonchimeras "${TMP}/${chimera_out}" 2> /dev/null
#   #echo ${chimera_out} chimera removed
#   )
# }
# export -f chimera_detection

echo "Step 5/9 : Chimera detection with vsearch - INACTIVATED"
# #Iterate in parallel
# find "${TMP}" -maxdepth 1 -name "FILTERED*.fastq.gz" | env TMP="${TMP}" QUAL="${QUAL}" MINL="${MINL}" MAXL="${MAXL}" ID="${ID}"\
    #   parallel -j "${NUM_PROCESSES}" chimera_detection

# #echo Filtered datasets are being deleted
# rm ${TMP}/FILTERED*

# #***************************************************************************************************************************


# Minimap2 alignments ***********************************************************************************************************

#SILVA="/database/SILVA_138.1_SSURef_tax_silva.fasta.gz"
#TAX="/database/Taxonomy_SILVA138.1.csv"
DB="/database"
#***************************************************************************************************************************

# Define a function to process each file
process_file() {
    FILE="$1"
    filename=$(basename "$1")
    outsamtools_file="Unmatched_$filename"
    output_file="ASV_abundance_$filename"
    minimap2 -a $IDX "${FILE}" 2> /dev/null > ${FILE}.sam
    samtools fastq -f 4 "${FILE}.sam" 2> /dev/null > ${TMP}/${outsamtools_file}  #Uncomment to remove verbose
    samtools view -h -b "${FILE}.sam" -o "${FILE}.bam"
    samtools sort "${FILE}.bam" > "${FILE}_sorted.bam"
    #echo "Bam file is sorted - Indexing"
    samtools index "${FILE}_sorted.bam"
    samtools view -F 4 "${FILE}_sorted.bam" | \
        tee >(cut -f 1,2,3 > "${FILE}_Exact_affiliations.tsv") | \
        cut -f 3 | sort | uniq -c | awk '$1 != 0' | sort -nr > "${TMP}/${output_file}.tsv"
    sed -i 's/^[[:space:]]*//' ${TMP}/${output_file}.tsv
    grep -o '[^ ]\+$' ${TMP}/${output_file}.tsv > "${TMP}/${filename}_ASV_list.tsv"
    barcode_number=$(echo "$filename" | sed -E 's/.*barcode([0-9]+).*\.fastq.gz/\1/')
    output_tax="Taxonomy_barcode${barcode_number}.csv"
    grep -f "${TMP}/${filename}_ASV_list.tsv" "${TAX}" > ${TMP}/${output_tax}
    rm ${FILE}.sam ${FILE}.bam ${FILE}_sorted.bam ${FILE}_sorted.bam.bai
}

# Export the function
export -f process_file
#***************************************************************************************************************************
echo "Step 6/9 : Reads alignements with minimap2 against $DATABASE"
# Iterate over the files in parallel
find "${TMP}" -maxdepth 1 -name "SUB_CHOPED_FILTERED_barcode*.fastq.gz" | env TMP="${TMP}" QUAL="${QUAL}" \
                                                                              MINL="${MINL}" MAXL="${MAXL}" ID="${ID}" DATABASE="${DATABASE}" TAX="${TAX}" IDX="${IDX}" parallel -j "${NUM_PROCESSES}" process_file

#***************************************************************************************************************************

# Homogenization of exact affiliations file names **************************************************************************
(cd ${TMP}
 for file in SUB_CHOPED_FILTERED_barcode*.fastq.gz_Exact_affiliations.tsv; do
     barcode_number=$(echo "$file" | sed -E 's/.*barcode([0-9]+).*\.tsv/\1/')
     new_file="barcode${barcode_number}_exact_affiliations.tsv"
     mv "$file" "$new_file"
 done

 #***************************************************************************************************************************

 # Homogeneization of ASV table names ***************************************************************************************
 for file in ASV_abundance_SUB_CHOPED_FILTERED_barcode*.fastq.gz.tsv; do
     barcode_number=$(echo "$file" | sed -E 's/.*barcode([0-9]+).*\.tsv/\1/')
     new_file="barcode${barcode_number}_abundance.tsv"
     mv "$file" "$new_file"
 done
)
#***************************************************************************************************************************

# Clustering step **********************************************************************************************************

# This function to homogeneize names
(cd ${TMP}
 for file in Unmatched_SUB_CHOPED_FILTERED_barcode*.fastq.gz; do
     if [ -e "$file" ]; then
         newname=$(echo "$file" | sed 's/Unmatched_SUB_CHOPED_FILTERED_barcode\([0-9]\+\)\.fastq.gz/barcode\1_unmatched.fastq.gz/')
         mv "$file" "$newname"
     fi
 done
)
#***************************************************************************************************************************

#This function to add barcode identifier to fasta header to retrieve abundance after clustering ****************************
(cd ${TMP}
 for file in barcode*_unmatched.fastq.gz; do
     if [ -e "$file" ]; then
         sample=$(echo "$file" | \
                      sed 's/barcode\(.*\)_unmatched.fastq.gz/\1/');\
             awk '{if (NR%4==1) {sub("^@", "@"); print $0 ";barcodelabel=barcode'"$sample"'"} else print $0}' "$file" >\
                 "$file.tmp" && mv "$file.tmp" "$file";
     fi
 done
)
#***************************************************************************************************************************

# Vsearch Unknown sequences clustering step ********************************************************************************
UNIQ_ID=$(uuidgen)
(cd "${TMP}"
 cat barcode*_unmatched.fastq.gz > seqs 2> /dev/null
 # Check if seqs is not empty
 if [[ -s "seqs" ]] ; then
     echo "Step 7/9 : Unknown sequences clustering with vsearch"

     # clusterize, and eliminate low-abundant clusters
     vsearch \
         --cluster_size seqs \
         --threads "${NUM_PROCESSES}" \
         --id "${ID}" \
         --relabel "${UNIQ_ID}_Unknown_cluster_" \
         --sizeout \
         --otutabout >(awk -v MINAB="${MINAB}" \
                       'BEGIN {FS = OFS = "\t"}
                        NR == 1 {print $0}
                        NR > 1 {s = 0
                                for (i=2; i<=NF; i++) {s += $i}
                                if (s >= MINAB) {print $0}
                        }' > unknown_clusters.tsv) \
         --clusterout_id \
         --clusterout_sort \
         --fasta_width 0 \
         --quiet \
         --consout - | \
         sed -E '/^>/ s/^>centroid=/>/ ; s/;seqs=[1-9]+//' | \
         vsearch \
             --fastx_filter - \
             --sizein \
             --sizeout \
             --quiet \
             --minsize "${MINAB}" \
             --fastaout Consensus_seq_OTU.fasta

     rm seqs

     # check if there are clusters with abundance >= MINAB
     if [[ ! -s Consensus_seq_OTU.fasta ]] ; then
         rm unknown_clusters.tsv Consensus_seq_OTU.fasta
         echo "No unknown cluster with abondance greater than ${MINAB}"
     fi
     # If by any mean you don't have any unknown sequence, then you'll
     # just skip the step (highly improbable)
 else
     echo "Step 7/9 : Skipped - no unknown sequence"
 fi
)


# Create phylogeny with MAFFT and FastTree *********************************************************************************

## Get every identified ASV ID

if [ "$TREE" -eq 1 ]; then
    echo "Step 8/9 : Phylogeny with MAFFT and FastTree"
    (cd ${TMP}

     #Fred's solution

     zgrep --no-group-separator -A 1 -f <(cat *_ASV_list.tsv) "${DATABASE}" > ALL_ASV.fasta
     # zgrep \
         #   --no-group-separator \
         #   --after-context 1 \
         #   --file <(cat *_ASV_list.tsv | sort -u) \
         #   "${DATABASE}" > ALL_ASV.fasta

     #Check if unknown sequences and add them to the fasta file for tree generation if any.
     cp ALL_ASV.fasta ALL_ASV_OTU.fasta
     [[ -e "Consensus_seq_OTU.fasta" ]] && cat Consensus_seq_OTU.fasta >> ALL_ASV_OTU.fasta


     ## MAFFT alignement ********************************************************************************************************
     mafft --thread "${NUM_PROCESSES}" ALL_ASV_OTU.fasta > ALL_ASV.aln 2> /dev/null


     ## FastTree ****************************************************************************************************************
     FastTree -nt -fastest ALL_ASV.aln > ASV.tree 2> /dev/null #Verbose debugging

    )
else
    echo "Step 8/9 : SKIPPED - Phylogeny with MAFFT and FastTree"
fi

## Export results **********************************************************************************************************
(cd ${TMP}
 mv *_abundance.tsv ${OUTPWD}/Results/ASV/
 mv Taxonomy*.csv ${OUTPWD}/Results/Tax/
 mv *_exact_affiliations.tsv ${OUTPWD}/Results/Exact_affiliations/
 mv ASV.tree ${OUTPWD}/Results/Phylogeny/

 if [ -e "Consensus_seq_OTU.fasta" ]; then
     mv Consensus_seq_OTU.fasta unknown_clusters.tsv  ${OUTPWD}/Results/Unknown_clusters/ 2> /dev/null
 fi


)
rm -r ${TMP}
#***************************************************************************************************************************

##Production of phyloseq object ********************************************************************************************
echo "Step 9/9 : Phylosequization with R and phyloseq"
Rscript /script.r "${DIR}" "${OUTPWD}" "${R_CLEANING}" "${TREE}" "${METADATA}" 2> /dev/null
#***************************************************************************************************************************
declare -ir TIME=$(( $(date +%s) - ${START} ))
#***************************************************************************************************************************
echo "Data treatment is over."
echo "NanoASV took ${TIME} seconds to perform."
echo "Don't forget to cite NanoASV and its dependencies if it allows you to treat your data."
