#!/bin/bash

# Research Dataset Generator Script
# Creates a realistic dataset with various file types and sizes

set -e

# Configuration
DATASET_DIR="research_dataset_$(date +%Y%m%d_%H%M%S)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if ImageMagick is available
check_imagemagick() {
    if ! command -v magick >/dev/null 2>&1; then
        print_warning "ImageMagick not found. Installing fallback method for images."
        return 1
    fi
    return 0
}

# Optimized function to generate random text content
generate_text_content() {
    local lines=$1
    local words_per_line=${2:-10}
    local target_size_mb=${3:-1}

    # Calculate total words needed
    local total_words=$((lines * words_per_line))

    # Pre-generate a large pool of random words to avoid repeated openssl calls
    local word_pool_size=10000
    local word_pool=$(openssl rand -hex $((word_pool_size * 4)) | sed 's/\(..\)/\1 /g' | tr ' ' '\n' | head -n $word_pool_size)

    # Convert to array for faster access
    local -a words_array
    readarray -t words_array <<< "$word_pool"
    local pool_size=${#words_array[@]}

    # Generate content more efficiently
    local word_count=0
    local line_word_count=0

    for ((i=1; i<=lines; i++)); do
        line_word_count=0
        for ((j=1; j<=words_per_line; j++)); do
            # Use modulo to cycle through word pool
            local word_index=$((word_count % pool_size))
            printf "%s " "${words_array[$word_index]}"
            ((word_count++))
            ((line_word_count++))
        done
        echo ""
    done
}

# Alternative (fast) text generation using /dev/urandom and base64
generate_text_content_fast() {
    local target_size_mb=$1

    # Generate random data and convert to readable text
    dd if=/dev/urandom bs=1M count="${target_size_mb%.*}" 2>/dev/null | \
    base64 | \
    sed 's/./& /g' | \
    sed 's/[^a-zA-Z0-9 ]//g' | \
    fold -w 80 | \
    head -n $((target_size_mb * 1024 * 1024 / 77))
}

# Fast generation of CSV file lines (using 32k character notes)
generate_csv() {
    local target_size_mb=$1
    local target_size_chars=$(($1 * 1024 * 1024))

    echo "id,timestamp,value,category,description,notes"

    local base_timestamp=1000000000
    local char_count=0

    # Use printf and bash arithmetic for speed
    while [ $char_count -lt $((target_size_chars)) ]; do
      local timestamp=$((base_timestamp + i * 60))
      local value=$((RANDOM * 1000 / 32767))
      local category=$((RANDOM % 10))
      local desc_num=$((RANDOM))
      local note128k=$(dd if=/dev/urandom bs=32K count=2 2>/dev/null | base64 | sed 's/./& /g' | sed 's/[^a-zA-Z0-9 ]//g' | cut -c -32768)

      local line=$(printf "%d,%s,%.2f,category_%d,desc_%x,%s\n" \
                          "$i" \
                          "$(date -d "@$timestamp" '+%Y-%m-%d %H:%M:%S')" \
                          "$value" \
                          "$category" \
                          "$desc_num" \
                          "$note128k")
      char_count=$((char_count + ${#line}))
      echo "$line"

    done
}

# Function to create microscopy-style image
create_microscopy_image() {
    local filepath="$1"
    local width=${2:-2048}
    local height=${3:-1536}
    printf "\t - %s\n" "$filepath"

    # Create a base noisy image
    magick -size "${width}x${height}" xc:black \
        \( +clone +noise Random \) \
        -compose Lighten -composite \
        \( +clone -blur 0x0.5 \) \
        -compose Multiply -composite \
        \( +clone -colorize 20,30,80 \) \
        -compose Screen -composite \
        -modulate 80,150,100 \
        "$filepath"
}

# Function to create field photo-style image
create_field_photo() {
    local filepath="$1"
    local width=${2:-1920}
    local height=${3:-1080}
    printf "\t - %s\n" "$filepath"
    
    # Create a landscape-style image
    magick -size $"{width}x${height}" \
        gradient:"#87CEEB-#228B22" \
        \( +clone +noise Random -blur 0x1 \) \
        -compose Multiply -composite \
        -modulate 90,120,110 \
        "$filepath"
}

# Function to create scientific chart/diagram
create_scientific_chart() {
    local filepath="$1"
    local width=${2:-800}
    local height=${3:-600}
    printf "\t - %s\n" "$filepath"
    
    # Create a chart-like image with grid and data points
    magick -size ${width}x${height} xc:white \
        \( -size ${width}x${height} xc:none -stroke gray -strokewidth 1 \
           -draw "line 50,50 50,$((height-50)) line 50,$((height-50)) $((width-50)),$((height-50))" \
           -draw "line 50,150 $((width-50)),150 line 50,250 $((width-50)),250 line 50,350 $((width-50)),350" \
           -draw "line 150,50 150,$((height-50)) line 250,50 250,$((height-50)) line 350,50 350,$((height-50))" \) \
        -compose Over -composite \
        \( +clone -fill red -stroke red -strokewidth 2 \
           -draw "circle 100,200 105,205 circle 200,180 205,185 circle 300,220 305,225 circle 400,160 405,165" \) \
        -compose Over -composite \
        "$filepath"
}

# Function to create satellite-style image
create_satellite_image() {
    local filepath="$1"
    local width=${2:-4096}
    local height=${3:-4096}
    printf "\t - %s\n" "$filepath"
    
    # Create a large, complex satellite-style image
    magick -size ${width}x${height} \
        plasma:fractal \
        -blur 0x2 \
        -modulate 70,200,120 \
        -colorize 0,20,40 \
        \( +clone +noise Random -blur 0x0.5 \) \
        -compose Multiply -composite \
        "$filepath"
}

# Function to create spectrogram-style image
create_spectrogram() {
    local filepath="$1"
    local width=${2:-1024}
    local height=${3:-768}
    printf "\t - %s\n" "$filepath"
    
    # Create a spectrogram-like visualization
    magick -size ${width}x${height} xc:black \
        +noise Random \
        -blur 0x1 \
        -normalize \
        -colorspace HSL \
        -channel Hue -evaluate set 60% \
        -channel Saturation -evaluate set 80% \
        -colorspace sRGB \
        "$filepath"
}

# Function to create lab equipment photo
create_lab_photo() {
    local filepath="$1"
    local width=${2:-1280}
    local height=${3:-960}
    printf "\t - %s\n" "$filepath"
    
    # Create a lab-like environment image
    magick -size ${width}x${height} \
        gradient:"#F5F5F5-#E0E0E0" \
        \( +clone +noise Gaussian -blur 0x0.5 \) \
        -compose Multiply -composite \
        \( -size 200x300 xc:"#C0C0C0" \) \
        -gravity Center -compose Over -composite \
        -modulate 95,80,105 \
        "$filepath"
}

# Function to create a file of specific size (non-image)
create_file_with_size() {
    local filepath="$1"
    local size_mb="$2"
    local file_type="$3"
    printf "\t - %s\n" "$filepath"

    case "$file_type" in
        "text")
            generate_text_content_fast "$size_mb" > "$filepath"
            ;;
        "binary"|"archive")
            # Use dd to create binary files
            dd if=/dev/urandom of="$filepath" bs=1M count="$size_mb" 2>/dev/null
            ;;
        "csv")
            # Use optimized CSV generation
            generate_csv "$size_mb" > "$filepath"
            ;;
        *)
            dd if=/dev/urandom of="$filepath" bs=1M count="$size_mb" 2>/dev/null
            ;;
    esac
}

# Function to create directory structure
create_directories() {
    print_status "Creating directory structure..."
    
    mkdir -p "$DATASET_DIR"/01_raw_data/{images,documents,archives,sensor_data}
    mkdir -p "$DATASET_DIR"/02_processed_data/{cleaned,analyzed,transformed}
    mkdir -p "$DATASET_DIR"/03_results/{figures,tables,reports}
    mkdir -p "$DATASET_DIR"/04_code/{scripts,notebooks,utilities}
    mkdir -p "$DATASET_DIR"/05_documentation/{readme,protocols,notes}
    mkdir -p "$DATASET_DIR"/06_backup/{daily,weekly,monthly}
}

# Function to generate research documents
generate_research_files() {
    print_status "Generating research documents..."
    
    local docs_dir="$DATASET_DIR/01_raw_data/documents"
    
    # Research papers and notes
    create_file_with_size "$docs_dir/literature_review.txt" 5 "text"
    create_file_with_size "$docs_dir/methodology_notes.txt" 3 "text"
    create_file_with_size "$docs_dir/experiment_log.txt" 8 "text"
    create_file_with_size "$docs_dir/observations.txt" 12 "text"
    
    # Create some "PDF" files (binary)
    create_file_with_size "$docs_dir/research_paper_draft.pdf" 15 "binary"
    create_file_with_size "$docs_dir/conference_presentation.pdf" 25 "binary"
    create_file_with_size "$docs_dir/grant_proposal.pdf" 8 "binary"
}

# Function to generate image files using ImageMagick
generate_image_files() {
    print_status "Generating image files..."
    
    local img_dir="$DATASET_DIR/01_raw_data/images"
    
    if check_imagemagick; then
        print_status "Using ImageMagick to create realistic images..."
        
        # High-resolution microscopy images (TIFF format for scientific use)
        print_status "Creating microscopy images..."
        create_microscopy_image "$img_dir/microscopy_001.tiff" 2048 1536
        create_microscopy_image "$img_dir/microscopy_002.tiff" 2048 1536
        create_microscopy_image "$img_dir/microscopy_003.tiff" 1024 768
        
        # Convert one to different bit depth for variety
        magick "$img_dir/microscopy_003.tiff" -depth 16 "$img_dir/microscopy_003_16bit.tiff"
        rm "$img_dir/microscopy_003.tiff"
        
        # Field photographs (JPEG format)
        print_status "Creating field photos..."
        create_field_photo "$img_dir/field_photo_001.jpg" 1920 1080
        create_field_photo "$img_dir/field_photo_002.jpg" 1280 960
        create_field_photo "$img_dir/field_site_panorama.jpg" 3840 1080
        
        # Scientific diagrams and charts (PNG format for crisp graphics)
        print_status "Creating scientific diagrams..."
        create_scientific_chart "$img_dir/measurement_chart.png" 800 600
        create_scientific_chart "$img_dir/correlation_plot.png" 1024 768
        
        # Spectrogram/analysis images
        create_spectrogram "$img_dir/frequency_analysis.png" 1024 768
        create_spectrogram "$img_dir/signal_spectrogram.png" 2048 1024
        
        # Large satellite/aerial imagery
        print_status "Creating satellite imagery (this may take a moment)..."
        create_satellite_image "$img_dir/satellite_overview.tiff" 4096 4096
        
        # Lab equipment photos
        create_lab_photo "$img_dir/lab_setup_001.jpg" 1280 960
        create_lab_photo "$img_dir/equipment_detail.jpg" 1920 1080
        
        # Create some processed/analyzed versions
        print_status "Creating processed image variants..."
        magick "$img_dir/field_photo_001.jpg" -colorspace Gray "$img_dir/field_photo_001_grayscale.jpg"
        magick "$img_dir/microscopy_001.tiff" -enhance -contrast-stretch 2%x98% "$img_dir/microscopy_001_enhanced.tiff"
        
        # Batch of smaller images (like time series)
        for i in {1..5}; do
            create_microscopy_image "$img_dir/timeseries_$(printf "%03d" $i).jpg" 512 384
        done
        
    else
        print_warning "ImageMagick not available, creating binary image files..."
        # Fallback to binary files with appropriate sizes
        create_file_with_size "$img_dir/microscopy_001.tiff" 45 "binary"
        create_file_with_size "$img_dir/microscopy_002.tiff" 52 "binary"
        create_file_with_size "$img_dir/field_photo_001.jpg" 8 "binary"
        create_file_with_size "$img_dir/field_photo_002.jpg" 12 "binary"
        create_file_with_size "$img_dir/diagram_01.png" 3 "binary"
        create_file_with_size "$img_dir/chart_analysis.png" 2 "binary"
        create_file_with_size "$img_dir/satellite_image.tiff" 150 "binary"
        create_file_with_size "$img_dir/lab_setup.jpg" 6 "binary"
    fi
}

# Function to generate data files
generate_data_files() {
    print_status "Generating data files..."
    
    local sensor_dir="$DATASET_DIR/01_raw_data/sensor_data"
    local processed_dir="$DATASET_DIR/02_processed_data"
    
    # Raw sensor data (CSV format)
    create_file_with_size "$sensor_dir/temperature_readings.csv" 25 "csv"
    create_file_with_size "$sensor_dir/pressure_data.csv" 18 "csv"
    create_file_with_size "$sensor_dir/humidity_measurements.csv" 22 "csv"
    create_file_with_size "$sensor_dir/gps_coordinates.csv" 12 "csv"
    
    # Large dataset files
    create_file_with_size "$sensor_dir/continuous_monitoring.dat" 500 "binary"
    create_file_with_size "$sensor_dir/high_frequency_data.bin" 750 "binary"
    
    # Processed data
    create_file_with_size "$processed_dir/cleaned/filtered_temperature.csv" 15 "csv"
    create_file_with_size "$processed_dir/analyzed/statistical_summary.txt" 2 "text"
    create_file_with_size "$processed_dir/transformed/normalized_data.csv" 30 "csv"
}

# Function to generate archive files
generate_archives() {
    print_status "Generating archive files..."
    
    local archive_dir=$( realpath "$DATASET_DIR/01_raw_data/archives" )
    local backup_dir=$( realpath "$DATASET_DIR/06_backup" )
    
    # Create some temporary files to archive
    local temp_dir=$(mktemp -d)
    create_file_with_size "$temp_dir/data1.txt" 10 "text"
    create_file_with_size "$temp_dir/data2.txt" 15 "text"
    create_file_with_size "$temp_dir/binary_data.bin" 20 "binary"
    
    # Create ZIP archives
    (cd "$temp_dir" && zip -q "$archive_dir/experimental_data_batch1.zip" *)
    
    # Create larger archive files
    create_file_with_size "$archive_dir/legacy_data.tar.gz" 200 "archive"
    create_file_with_size "$backup_dir/daily/backup_$(date +%Y%m%d).zip" 180 "archive"
    create_file_with_size "$backup_dir/weekly/weekly_backup.tar.gz" 450 "archive"
    
    # Large backup file (GB range)
    create_file_with_size "$backup_dir/monthly/full_backup_$(date +%Y%m).tar.gz" $((1024 * 2)) "archive"
    
    # Cleanup
    rm -rf "$temp_dir"
}

# Function to generate code and script files
generate_code_files() {
    print_status "Generating code files..."
    
    local code_dir="$DATASET_DIR/04_code"
    
    # Python scripts
    cat > "$code_dir/scripts/data_analysis.py" << 'EOF'
#!/usr/bin/env python3
"""
Data analysis script for research project
"""
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
from PIL import Image
import cv2

def load_data(filename):
    """Load data from CSV file"""
    return pd.read_csv(filename)

def analyze_temperature(data):
    """Analyze temperature patterns"""
    stats = data['temperature'].describe()
    return stats

def process_microscopy_image(image_path):
    """Process microscopy images for analysis"""
    img = cv2.imread(image_path)
    # Apply filters and enhancements
    processed = cv2.GaussianBlur(img, (5, 5), 0)
    return processed

def create_visualization(data, output_path):
    """Create data visualization"""
    plt.figure(figsize=(10, 6))
    plt.plot(data['timestamp'], data['value'])
    plt.title('Sensor Data Over Time')
    plt.xlabel('Time')
    plt.ylabel('Value')
    plt.savefig(output_path)
    plt.close()

if __name__ == "__main__":
    print("Starting data analysis...")
    # Load sensor data
    temp_data = load_data("../01_raw_data/sensor_data/temperature_readings.csv")
    
    # Analyze and save results
    stats = analyze_temperature(temp_data)
    print("Temperature statistics:", stats)
    
    # Create visualization
    create_visualization(temp_data, "../03_results/figures/temperature_analysis.png")
EOF

    # R script with imaging focus
    cat > "$code_dir/scripts/image_analysis.R" << 'EOF'
# Image and Statistical Analysis Script
# Research Project Data Analysis

library(ggplot2)
library(dplyr)
library(imager)  # For image processing

# Load sensor data
data <- read.csv("../01_raw_data/sensor_data/temperature_readings.csv")

# Basic statistics
summary(data)

# Image analysis function
process_microscopy <- function(image_path) {
  # Load and process microscopy image
  img <- load.image(image_path)
  
  # Apply filters
  filtered <- isoblur(img, sigma = 1)
  
  return(filtered)
}

# Create plots
temp_plot <- ggplot(data, aes(x=timestamp, y=value)) + 
             geom_line(color="blue", size=1) + 
             geom_smooth(method="loess", color="red") +
             labs(title="Temperature Measurements Over Time",
                  x="Time", y="Temperature (°C)") +
             theme_minimal()

ggsave("../03_results/figures/temperature_trend_analysis.png", temp_plot, 
       width=12, height=8, dpi=300)

# Statistical analysis
correlation_analysis <- cor(data[,sapply(data, is.numeric)])
write.csv(correlation_analysis, "../03_results/tables/correlation_matrix.csv")

print("Analysis complete!")
EOF

    # Jupyter notebook (JSON format)
    cat > "$code_dir/notebooks/image_processing_workflow.ipynb" << 'EOF'
{
 "cells": [
  {
   "cell_type": "markdown",
   "metadata": {},
   "source": [
    "# Image Processing and Analysis Workflow\n",
    "Processing microscopy and field images for research analysis"
   ]
  },
  {
   "cell_type": "code",
   "execution_count": null,
   "metadata": {},
   "outputs": [],
   "source": [
    "import pandas as pd\nimport numpy as np\nimport matplotlib.pyplot as plt\nfrom PIL import Image\nimport cv2\nfrom skimage import filters, morphology\n\n# Image processing pipeline\ndef process_microscopy_batch(image_dir):\n    \"\"\"Process a batch of microscopy images\"\"\"\n    processed_images = []\n    \n    for image_file in os.listdir(image_dir):\n        if image_file.endswith('.tiff'):\n            img_path = os.path.join(image_dir, image_file)\n            img = cv2.imread(img_path, cv2.IMREAD_GRAYSCALE)\n            \n            # Apply preprocessing\n            enhanced = cv2.equalizeHist(img)\n            denoised = cv2.bilateralFilter(enhanced, 9, 75, 75)\n            \n            processed_images.append(denoised)\n    \n    return processed_images\n\nprint('Image processing notebook loaded')"
   ]
  },
  {
   "cell_type": "markdown",
   "metadata": {},
   "source": [
    "## Load and Display Sample Images"
   ]
  },
  {
   "cell_type": "code",
   "execution_count": null,
   "metadata": {},
   "outputs": [],
   "source": [
    "# Load sample microscopy image\nimg_path = '../01_raw_data/images/microscopy_001.tiff'\nif os.path.exists(img_path):\n    sample_img = Image.open(img_path)\n    plt.figure(figsize=(10, 8))\n    plt.imshow(sample_img, cmap='gray')\n    plt.title('Sample Microscopy Image')\n    plt.axis('off')\n    plt.show()\nelse:\n    print('Sample image not found')"
   ]
  }
 ],
 "metadata": {
  "kernelspec": {
   "display_name": "Python 3",
   "language": "python",
   "name": "python3"
  },
  "language_info": {
   "name": "python",
   "version": "3.8.0"
  }
 },
 "nbformat": 4,
 "nbformat_minor": 4
}
EOF

    # Shell script for batch processing
    cat > "$code_dir/utilities/batch_process_images.sh" << 'EOF'
#!/bin/bash
# Batch image processing utility

echo "Starting batch image processing..."

IMAGE_DIR="../01_raw_data/images"
OUTPUT_DIR="../02_processed_data/images"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Process TIFF files (microscopy images)
echo "Processing microscopy images..."
for file in "$IMAGE_DIR"/*.tiff; do
    if [[ -f "$file" ]]; then
        filename=$(basename "$file" .tiff)
        echo "Processing $filename..."
        
        # Example ImageMagick processing commands
        if command -v magick >/dev/null 2>&1; then
            # Enhance contrast and reduce noise
            magick "$file" -enhance -noise 1 -normalize "$OUTPUT_DIR/${filename}_processed.tiff"
            
            # Create thumbnail
            magick "$file" -resize 256x256 "$OUTPUT_DIR/${filename}_thumb.jpg"
        fi
    fi
done

# Process JPEG files (field photos)
echo "Processing field photos..."
for file in "$IMAGE_DIR"/*.jpg; do
    if [[ -f "$file" ]]; then
        filename=$(basename "$file" .jpg)
        echo "Processing $filename..."
        
        if command -v magick >/dev/null 2>&1; then
            # Auto-level and sharpen
            magick "$file" -auto-level -unsharp 0x1 "$OUTPUT_DIR/${filename}_enhanced.jpg"
        fi
    fi
done

echo "Batch processing complete!"
echo "Processed images saved to: $OUTPUT_DIR"
EOF

    chmod +x "$code_dir/utilities/batch_process_images.sh"
}

# Function to generate documentation
generate_documentation() {
    print_status "Generating documentation..."
    
    local doc_dir="$DATASET_DIR/05_documentation"
    
    # README file
    cat > "$doc_dir/readme/README.md" << EOF
# Research Dataset

Generated on: $(date)
Generated with: ImageMagick $(command -v magick >/dev/null 2>&1 && magick -version | head -1 || echo "Not available")

## Overview
This dataset contains research data collected for [Project Name] study, including high-resolution microscopy images, field photographs, sensor data, and analysis results.

## Directory Structure
- \`01_raw_data/\` - Original, unprocessed data
  - \`images/\` - Microscopy images (TIFF), field photos (JPEG), diagrams (PNG)
  - \`sensor_data/\` - CSV files with measurement data
  - \`documents/\` - Research documents and papers
  - \`archives/\` - Compressed historical data
- \`02_processed_data/\` - Cleaned and processed data
- \`03_results/\` - Analysis results and outputs
- \`04_code/\` - Analysis scripts and code
- \`05_documentation/\` - Project documentation
- \`06_backup/\` - Backup files

## Image Data Details
### Microscopy Images
- Format: TIFF (16-bit and 8-bit)
- Resolution: 2048x1536 pixels (high-res), 1024x768 (standard)
- Content: Simulated microscopic structures with realistic noise patterns

### Field Photography
- Format: JPEG
- Resolution: 1920x1080, 1280x960
- Content: Landscape-style field site documentation

### Scientific Diagrams
- Format: PNG
- Resolution: 800x600, 1024x768
- Content: Charts, plots, and measurement visualizations

### Satellite Imagery
- Format: TIFF
- Resolution: 4096x4096 pixels
- Content: Large-scale terrain simulation

## File Sizes
- Total dataset size: ~4-6 GB
- Microscopy images: 5-50 MB each
- Field photos: 2-15 MB each
- Satellite imagery: 100-200 MB
- Sensor data files: 10-500 MB

## Processing Workflow
1. Raw images in \`01_raw_data/images/\`
2. Batch processing scripts in \`04_code/utilities/\`
3. Processed results in \`02_processed_data/\`
4. Analysis notebooks in \`04_code/notebooks/\`

## Usage Examples
\`\`\`bash
# Batch process images
cd 04_code/utilities
./batch_process_images.sh

# Run data analysis
cd 04_code/scripts
python3 data_analysis.py

# R statistical analysis
Rscript image_analysis.R
\`\`\`

## Software Requirements
- ImageMagick (for image processing)
- Python 3.x with PIL, OpenCV, scikit-image
- R with ggplot2, dplyr, imager packages

## Contact
[Researcher Name] - [email]
EOF

    # Image processing protocol
    cat > "$doc_dir/protocols/image_processing_protocol.md" << 'EOF'
# Image Processing Protocol

## Equipment and Setup
- High-resolution microscope with TIFF output capability
- Field camera with GPS tagging
- Consistent lighting conditions for lab photography

## Image Acquisition Standards
### Microscopy Images
1. **Resolution**: Minimum 1024x768, preferred 2048x1536
2. **Format**: TIFF (uncompressed) for analysis, JPEG for documentation
3. **Bit Depth**: 16-bit for quantitative analysis, 8-bit for visualization
4. **Naming Convention**: `microscopy_XXX.tiff` where XXX is sequential number

### Field Photography
1. **Resolution**: 1920x1080 minimum
2. **Format**: JPEG with maximum quality setting
3. **Metadata**: Include GPS coordinates and timestamp
4. **Naming Convention**: `field_photo_XXX.jpg` or `site_location_YYYYMMDD.jpg`

## Processing Pipeline
1. **Quality Check**: Verify image integrity and metadata
2. **Preprocessing**: 
   - Noise reduction (bilateral filter)
   - Contrast enhancement (histogram equalization)
   - Normalization for batch processing
3. **Analysis Preparation**:
   - Convert to appropriate color space
   - Create analysis masks if needed
   - Generate thumbnails for quick review

## Quality Control
- Visual inspection of all processed images
- Verify processing parameters are consistent
- Document any anomalies or processing issues
- Maintain original files alongside processed versions

## Archive and Backup
- Raw images: Long-term storage with metadata
- Processed images: Working directory with version control
- Regular backup verification
EOF

    # Research notes
    create_file_with_size "$doc_dir/notes/image_analysis_notes.txt" 15 "text"
    create_file_with_size "$doc_dir/notes/field_work_log.txt" 20 "text"
}

# Function to create result files (including processed images)
generate_results() {
    print_status "Generating result files..."
    
    local results_dir="$DATASET_DIR/03_results"
    
    if check_imagemagick; then
        # Generate result visualizations
        print_status "Creating result visualizations..."
        
        # Scientific plots and charts
        create_scientific_chart "$results_dir/figures/temperature_correlation.png" 1024 768
        create_scientific_chart "$results_dir/figures/statistical_summary.png" 800 600
        create_spectrogram "$results_dir/figures/frequency_domain_analysis.png" 1200 800
        
        # Create a comparison figure (before/after style)
        magick -size 1200x400 xc:white \
            \( -size 580x380 gradient:"#FF0000-#00FF00" \) -geometry +10+10 -composite \
            \( -size 580x380 gradient:"#0000FF-#FFFF00" \) -geometry +610+10 -composite \
            -font Arial -pointsize 24 -fill black \
            -annotate +250+50 "Before" -annotate +850+50 "After" \
            "$results_dir/figures/processing_comparison.png"
            
    else
        # Fallback to binary files
        create_file_with_size "$results_dir/figures/temperature_trend.png" 3 "binary"
        create_file_with_size "$results_dir/figures/correlation_matrix.png" 4 "binary"
        create_file_with_size "$results_dir/figures/spatial_distribution.png" 8 "binary"
    fi
    
    # Tables and reports
    create_file_with_size "$results_dir/tables/summary_statistics.csv" 1 "csv"
    create_file_with_size "$results_dir/tables/image_analysis_results.csv" 3 "csv"
    create_file_with_size "$results_dir/reports/monthly_report.pdf" 12 "binary"
    create_file_with_size "$results_dir/reports/image_processing_report.pdf" 18 "binary"
    create_file_with_size "$results_dir/reports/final_analysis.docx" 8 "binary"
}

# Function to display dataset summary
display_summary() {
    print_success "Dataset generation complete!"
    echo
    print_status "Dataset Summary:"
    echo "================="
    
    if command -v du >/dev/null 2>&1; then
        echo "Total size: $(du -hs "$DATASET_DIR" | cut -f1)"
        echo
        echo "Directory sizes:"
        du -hs "$DATASET_DIR"/*/ | sort -hr
        echo
        echo "File count by type:"
        find "$DATASET_DIR" -type f -name "*.txt" | wc -l | xargs echo "Text files:"
        find "$DATASET_DIR" -type f -name "*.csv" | wc -l | xargs echo "CSV files:"
        find "$DATASET_DIR" -type f -name "*.jpg" -o -name "*.png" -o -name "*.tiff" | wc -l | xargs echo "Image files:"
        find "$DATASET_DIR" -type f -name "*.zip" -o -name "*.tar.gz" | wc -l | xargs echo "Archive files:"
        find "$DATASET_DIR" -type f -name "*.py" -o -name "*.R" -o -name "*.sh" -o -name "*.ipynb" | wc -l | xargs echo "Code files:"
        
        echo
        if check_imagemagick; then
            print_success "✓ Real images generated with ImageMagick"
            echo "Image formats created:"
            find "$DATASET_DIR" -name "*.tiff" | wc -l | xargs echo "  TIFF files (microscopy):"
            find "$DATASET_DIR" -name "*.jpg" | wc -l | xargs echo "  JPEG files (photography):"
            find "$DATASET_DIR" -name "*.png" | wc -l | xargs echo "  PNG files (diagrams):"
        else
            print_warning "⚠ ImageMagick not available - binary image files created instead"
        fi
    fi
    
    echo
    print_status "Dataset location: $(pwd)/$DATASET_DIR"
    print_status "Sample commands to explore:"
    echo "  ls -la $DATASET_DIR/01_raw_data/images/"
    if check_imagemagick; then
        echo "  identify $DATASET_DIR/01_raw_data/images/microscopy_001.tiff"
        echo "  display $DATASET_DIR/01_raw_data/images/field_photo_001.jpg"
    fi
    echo "  head -10 $DATASET_DIR/01_raw_data/sensor_data/temperature_readings.csv"
    
    print_success "Ready for research!"
}

# Main execution
main() {
    print_status "Starting research dataset generation with ImageMagick support..."
    echo
    
    # Check for required tools
    if ! command -v openssl >/dev/null 2>&1; then
        print_error "openssl is required but not installed. Please install it first."
        exit 1
    fi
    
    # Check ImageMagick availability
    if check_imagemagick; then
        print_success "ImageMagick detected - will generate real images!"
    else
        print_warning "ImageMagick not detected. To install on Ubuntu/Debian: sudo apt-get install imagemagick"
        print_warning "Will create binary files instead of real images."
    fi
    echo
    
    # Create the dataset
    create_directories
    generate_research_files
    generate_image_files
    generate_data_files
    generate_archives
    generate_code_files
    generate_documentation
    generate_results
    
    # Show summary
    display_summary
}

# Run the script
main "$@"
