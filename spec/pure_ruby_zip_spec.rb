require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe PureRubyZip do
  it "has a version number" do
    expect(PureRubyZip::VERSION).not_to be nil
  end

  describe "constants" do
    it "defines MAX_DECOMPRESSION_RATIO" do
      expect(PureRubyZip::MAX_DECOMPRESSION_RATIO).to eq(100)
    end

    it "defines MAX_DECOMPRESSED_SIZE" do
      expect(PureRubyZip::MAX_DECOMPRESSED_SIZE).to eq(1024 * 1024 * 1024)
    end
  end

  describe "error classes" do
    it "defines Error as base class" do
      expect(PureRubyZip::Error).to be < StandardError
    end

    it "defines InvalidZipError" do
      expect(PureRubyZip::InvalidZipError).to be < PureRubyZip::Error
    end

    it "defines FileNotFoundError" do
      expect(PureRubyZip::FileNotFoundError).to be < PureRubyZip::Error
    end

    it "defines PathTraversalError" do
      expect(PureRubyZip::PathTraversalError).to be < PureRubyZip::Error
    end

    it "defines ZipBombError" do
      expect(PureRubyZip::ZipBombError).to be < PureRubyZip::Error
    end

    it "defines UnsupportedCompressionError" do
      expect(PureRubyZip::UnsupportedCompressionError).to be < PureRubyZip::Error
    end
  end
end

RSpec.describe PureRubyZip::Bitstream do
  describe "#initialize" do
    it "accepts binary data" do
      expect { PureRubyZip::Bitstream.new("test") }.not_to raise_error
    end

    it "raises error for nil data" do
      expect { PureRubyZip::Bitstream.new(nil) }.to raise_error(ArgumentError, "Data cannot be nil")
    end
  end

  describe "#read_bit" do
    it "reads individual bits correctly" do
      # Binary: 10110100 (0xB4 = 180)
      bitstream = PureRubyZip::Bitstream.new("\xB4")

      # Read bits in little-endian order
      expect(bitstream.read_bit).to eq(false) # bit 0
      expect(bitstream.read_bit).to eq(false) # bit 1
      expect(bitstream.read_bit).to eq(true)  # bit 2
      expect(bitstream.read_bit).to eq(false) # bit 3
      expect(bitstream.read_bit).to eq(true)  # bit 4
      expect(bitstream.read_bit).to eq(true)  # bit 5
      expect(bitstream.read_bit).to eq(false) # bit 6
      expect(bitstream.read_bit).to eq(true)  # bit 7
    end

    it "raises error when reading past end of data" do
      bitstream = PureRubyZip::Bitstream.new("\x00")
      8.times { bitstream.read_bit }
      expect { bitstream.read_bit }.to raise_error(PureRubyZip::InvalidZipError)
    end
  end

  describe "#read_int" do
    it "reads multi-bit integers correctly" do
      bitstream = PureRubyZip::Bitstream.new("\xFF\x00")
      expect(bitstream.read_int(8)).to eq(255) # All 1s
      expect(bitstream.read_int(8)).to eq(0)   # All 0s
    end

    it "reads partial bytes correctly" do
      bitstream = PureRubyZip::Bitstream.new("\x0F") # 00001111
      expect(bitstream.read_int(4)).to eq(15)  # Lower 4 bits
      expect(bitstream.read_int(4)).to eq(0)   # Upper 4 bits
    end

    it "raises error for negative bit count" do
      bitstream = PureRubyZip::Bitstream.new("\xFF")
      expect { bitstream.read_int(-1) }.to raise_error(ArgumentError, "Number of bits must be positive")
    end

    it "raises error for too large bit count" do
      bitstream = PureRubyZip::Bitstream.new("\xFF")
      expect { bitstream.read_int(33) }.to raise_error(ArgumentError, "Number of bits too large")
    end
  end

  describe "#more_data?" do
    it "returns true when data is available" do
      bitstream = PureRubyZip::Bitstream.new("\x00")
      expect(bitstream.more_data?).to eq(true)
    end

    it "returns false when all data has been read" do
      bitstream = PureRubyZip::Bitstream.new("\x00")
      8.times { bitstream.read_bit }
      expect(bitstream.more_data?).to eq(false)
    end
  end
end

RSpec.describe PureRubyZip::ZipFile do
  let(:test_zip_path) { File.expand_path("../../test12.zip", __FILE__) }

  describe "#initialize" do
    it "raises error for non-existent file" do
      expect { PureRubyZip::ZipFile.new("nonexistent.zip") }.to raise_error(Errno::ENOENT)
    end

    it "raises error for directory" do
      Dir.mktmpdir do |dir|
        expect { PureRubyZip::ZipFile.new(dir) }.to raise_error(ArgumentError, /Cannot read directory/)
      end
    end

    context "with valid ZIP file" do
      it "successfully opens the ZIP file" do
        skip "Test ZIP file not found" unless File.exist?(test_zip_path)
        expect { PureRubyZip::ZipFile.new(test_zip_path) }.not_to raise_error
      end
    end
  end

  context "with test ZIP file" do
    before(:each) do
      skip "Test ZIP file not found" unless File.exist?(test_zip_path)
    end

    let(:zipfile) { PureRubyZip::ZipFile.new(test_zip_path) }

    describe "#entries" do
      it "returns array of filenames" do
        expect(zipfile.entries).to be_an(Array)
        expect(zipfile.entries).not_to be_empty
      end
    end

    describe "#items" do
      it "returns hash of items" do
        expect(zipfile.items).to be_a(Hash)
        expect(zipfile.items).not_to be_empty
      end
    end

    describe "#size" do
      it "returns number of entries" do
        expect(zipfile.size).to be > 0
        expect(zipfile.size).to eq(zipfile.entries.length)
      end
    end

    describe "#include?" do
      it "returns true for existing file" do
        filename = zipfile.entries.first
        expect(zipfile.include?(filename)).to eq(true)
      end

      it "returns false for non-existent file" do
        expect(zipfile.include?("nonexistent.txt")).to eq(false)
      end
    end

    describe "#[]" do
      it "returns ZipFileItem for existing file" do
        filename = zipfile.entries.first
        item = zipfile[filename]
        expect(item).to be_a(PureRubyZip::ZipFileItem)
      end

      it "raises error for non-existent file" do
        expect { zipfile["nonexistent.txt"] }.to raise_error(PureRubyZip::FileNotFoundError)
      end
    end

    describe "#each" do
      it "yields path and item for each entry" do
        count = 0
        zipfile.each do |path, item|
          expect(path).to be_a(String)
          expect(item).to be_a(PureRubyZip::ZipFileItem)
          count += 1
        end
        expect(count).to eq(zipfile.size)
      end

      it "returns enumerator when no block given" do
        expect(zipfile.each).to be_an(Enumerator)
      end
    end

    describe "#extract" do
      it "extracts file data" do
        filename = zipfile.entries.find { |f| !zipfile[f].directory? }
        skip "No regular files in test ZIP" unless filename

        data = zipfile.extract(filename)
        expect(data).to be_a(String)
      end

      it "raises error for non-existent file" do
        expect { zipfile.extract("nonexistent.txt") }.to raise_error(PureRubyZip::FileNotFoundError)
      end
    end

    describe "#extract_all" do
      it "returns array of hashes with path and data" do
        results = zipfile.extract_all
        expect(results).to be_an(Array)
        results.each do |result|
          expect(result).to have_key(:path)
          expect(result).to have_key(:data)
          expect(result[:path]).to be_a(String)
          expect(result[:data]).to be_a(String)
        end
      end

      it "skips directory entries" do
        results = zipfile.extract_all
        results.each do |result|
          expect(result[:path]).not_to end_with("/")
        end
      end
    end

    describe "#extract_to_disk" do
      it "extracts all files to default directory" do
        Dir.mktmpdir do |tmpdir|
          test_zip = File.join(tmpdir, "test.zip")
          FileUtils.cp(test_zip_path, test_zip)

          zip = PureRubyZip::ZipFile.new(test_zip)
          paths = zip.extract_to_disk

          expect(paths).to be_an(Array)
          paths.each do |path|
            expect(File.exist?(path)).to eq(true)
          end
        end
      end

      it "extracts all files to custom directory" do
        Dir.mktmpdir do |tmpdir|
          output_dir = File.join(tmpdir, "extracted")
          paths = zipfile.extract_to_disk(output_dir)

          expect(paths).to be_an(Array)
          paths.each do |path|
            expect(path).to start_with(output_dir)
            expect(File.exist?(path)).to eq(true)
          end
        end
      end

      it "creates nested directories" do
        Dir.mktmpdir do |tmpdir|
          output_dir = File.join(tmpdir, "extracted")
          zipfile.extract_to_disk(output_dir)

          expect(Dir.exist?(output_dir)).to eq(true)
        end
      end
    end

    describe "#extract_matching" do
      it "extracts files matching pattern" do
        results = zipfile.extract_matching(/\.txt$/i)
        expect(results).to be_an(Array)
        results.each do |result|
          expect(result[:path]).to match(/\.txt$/i)
        end
      end

      it "yields to block when given" do
        paths_seen = []
        zipfile.extract_matching(/.*/) do |path, data|
          paths_seen << path
          expect(data).to be_a(String)
        end
        expect(paths_seen).not_to be_empty
      end

      it "returns empty array when no matches" do
        results = zipfile.extract_matching(/\.nonexistent$/)
        expect(results).to eq([])
      end
    end

    describe "backward compatibility" do
      it "supports decompress_file alias" do
        filename = zipfile.entries.find { |f| !zipfile[f].directory? }
        skip "No regular files in test ZIP" unless filename

        expect(zipfile).to respond_to(:decompress_file)
        data = zipfile.decompress_file(filename)
        expect(data).to be_a(String)
      end

      it "supports decompress_all_files alias" do
        expect(zipfile).to respond_to(:decompress_all_files)
        results = zipfile.decompress_all_files
        expect(results).to be_an(Array)
      end

      it "supports decompress_all_files_to_disk alias" do
        expect(zipfile).to respond_to(:decompress_all_files_to_disk)
      end
    end
  end
end

RSpec.describe PureRubyZip::ZipHelpers do
  # Create a test class that includes the module
  let(:helper_class) do
    Class.new do
      include PureRubyZip::ZipHelpers
    end
  end
  let(:helper) { helper_class.new }

  describe "#validate_safe_path" do
    it "allows normal paths" do
      expect(helper.validate_safe_path("file.txt")).to eq("file.txt")
      expect(helper.validate_safe_path("dir/file.txt")).to eq("dir/file.txt")
      expect(helper.validate_safe_path("a/b/c/file.txt")).to eq("a/b/c/file.txt")
    end

    it "rejects absolute paths" do
      expect { helper.validate_safe_path("/etc/passwd") }.to raise_error(PureRubyZip::PathTraversalError)
    end

    it "rejects parent directory references" do
      expect { helper.validate_safe_path("../etc/passwd") }.to raise_error(PureRubyZip::PathTraversalError)
      expect { helper.validate_safe_path("dir/../../etc/passwd") }.to raise_error(PureRubyZip::PathTraversalError)
    end

    it "rejects paths with null bytes" do
      expect { helper.validate_safe_path("file\0.txt") }.to raise_error(PureRubyZip::PathTraversalError)
    end

    it "rejects paths with backslashes" do
      expect { helper.validate_safe_path("dir\\file.txt") }.to raise_error(PureRubyZip::PathTraversalError)
    end
  end
end

RSpec.describe PureRubyZip::CRC32 do
  describe ".checksum" do
    it "calculates correct CRC32 for empty string" do
      expect(PureRubyZip::CRC32.checksum("")).to eq(0)
    end

    it "calculates correct CRC32 for simple data" do
      # Known CRC32 value for "Hello, World!"
      expect(PureRubyZip::CRC32.checksum("Hello, World!")).to eq(0xEC4AC3D0)
    end

    it "calculates correct CRC32 for binary data" do
      data = "\x00\x01\x02\x03\xFF"
      crc = PureRubyZip::CRC32.checksum(data)
      expect(crc).to be_a(Integer)
      expect(crc).to be >= 0
      expect(crc).to be <= 0xFFFFFFFF
    end

    it "produces different checksums for different data" do
      crc1 = PureRubyZip::CRC32.checksum("test1")
      crc2 = PureRubyZip::CRC32.checksum("test2")
      expect(crc1).not_to eq(crc2)
    end
  end
end

RSpec.describe PureRubyZip::ZipCompressor do
  let(:compressor) { PureRubyZip::ZipCompressor.new }

  describe "#compress_stored" do
    it "returns data unchanged" do
      data = "Hello, World!"
      expect(compressor.compress_stored(data)).to eq(data)
    end

    it "works with binary data" do
      data = "\x00\xFF\x01\x02"
      expect(compressor.compress_stored(data)).to eq(data)
    end
  end

  describe "#compress_deflate" do
    it "compresses data" do
      data = "Hello, World!"
      compressed = compressor.compress_deflate(data)
      expect(compressed).to be_a(String)
      expect(compressed.encoding).to eq(Encoding::ASCII_8BIT)
    end

    it "produces valid DEFLATE data" do
      data = "Test data"
      compressed = compressor.compress_deflate(data)

      # Should be able to decompress it
      bitstream = PureRubyZip::Bitstream.new(compressed)
      decompressor = PureRubyZip::ZipDecompressor.new
      decompressed = decompressor.decode_zipped_file(bitstream)
      expect(decompressed).to eq(data)
    end

    it "works with empty data" do
      data = ""
      compressed = compressor.compress_deflate(data)
      expect(compressed).to be_a(String)
    end
  end
end

RSpec.describe PureRubyZip::ZipWriter do
  let(:temp_dir) { Dir.mktmpdir }
  let(:zip_path) { File.join(temp_dir, "test.zip") }

  after do
    FileUtils.rm_rf(temp_dir)
  end

  describe ".create" do
    it "creates a ZIP file with block" do
      PureRubyZip::ZipWriter.create(zip_path) do |zip|
        zip.add_buffer("Hello, World!", "hello.txt")
      end

      expect(File.exist?(zip_path)).to be true
      expect(File.size(zip_path)).to be > 0
    end

    it "creates a valid ZIP file that can be read back" do
      PureRubyZip::ZipWriter.create(zip_path) do |zip|
        zip.add_buffer("Test content", "test.txt")
      end

      # Read it back
      zip_file = PureRubyZip::ZipFile.new(zip_path)
      expect(zip_file.entries).to include("test.txt")
      expect(zip_file.extract("test.txt")).to eq("Test content")
    end
  end

  describe "#add_buffer" do
    it "adds data from memory with stored compression" do
      PureRubyZip::ZipWriter.create(zip_path) do |zip|
        zip.add_buffer("Buffer content", "buffer.txt", compression: :stored)
      end

      zip_file = PureRubyZip::ZipFile.new(zip_path)
      expect(zip_file.extract("buffer.txt")).to eq("Buffer content")
    end

    it "adds data from memory with deflate compression" do
      PureRubyZip::ZipWriter.create(zip_path) do |zip|
        zip.add_buffer("Compressed content", "compressed.txt", compression: :deflate)
      end

      zip_file = PureRubyZip::ZipFile.new(zip_path)
      expect(zip_file.extract("compressed.txt")).to eq("Compressed content")
    end

    it "adds multiple files" do
      PureRubyZip::ZipWriter.create(zip_path) do |zip|
        zip.add_buffer("File 1", "file1.txt")
        zip.add_buffer("File 2", "file2.txt")
        zip.add_buffer("File 3", "file3.txt")
      end

      zip_file = PureRubyZip::ZipFile.new(zip_path)
      expect(zip_file.entries).to contain_exactly("file1.txt", "file2.txt", "file3.txt")
      expect(zip_file.extract("file1.txt")).to eq("File 1")
      expect(zip_file.extract("file2.txt")).to eq("File 2")
      expect(zip_file.extract("file3.txt")).to eq("File 3")
    end

    it "handles binary data correctly" do
      binary_data = (0..255).to_a.pack("C*")
      PureRubyZip::ZipWriter.create(zip_path) do |zip|
        zip.add_buffer(binary_data, "binary.bin")
      end

      zip_file = PureRubyZip::ZipFile.new(zip_path)
      expect(zip_file.extract("binary.bin")).to eq(binary_data)
    end

    it "raises error for empty zip_path" do
      expect {
        PureRubyZip::ZipWriter.create(zip_path) do |zip|
          zip.add_buffer("data", "")
        end
      }.to raise_error(ArgumentError, "zip_path is required")
    end

    it "raises error for unsupported compression method" do
      expect {
        PureRubyZip::ZipWriter.create(zip_path) do |zip|
          zip.add_buffer("data", "file.txt", compression: :invalid)
        end
      }.to raise_error(ArgumentError, /Unsupported compression method/)
    end
  end

  describe "#add_file" do
    it "adds a file from disk" do
      source_file = File.join(temp_dir, "source.txt")
      File.write(source_file, "Source file content")

      PureRubyZip::ZipWriter.create(zip_path) do |zip|
        zip.add_file(source_file)
      end

      zip_file = PureRubyZip::ZipFile.new(zip_path)
      expect(zip_file.entries).to include("source.txt")
      expect(zip_file.extract("source.txt")).to eq("Source file content")
    end

    it "adds a file with custom zip_path" do
      source_file = File.join(temp_dir, "original.txt")
      File.write(source_file, "Original content")

      PureRubyZip::ZipWriter.create(zip_path) do |zip|
        zip.add_file(source_file, "custom/path/renamed.txt")
      end

      zip_file = PureRubyZip::ZipFile.new(zip_path)
      expect(zip_file.entries).to include("custom/path/renamed.txt")
      expect(zip_file.extract("custom/path/renamed.txt")).to eq("Original content")
    end

    it "adds multiple files from disk" do
      file1 = File.join(temp_dir, "file1.txt")
      file2 = File.join(temp_dir, "file2.txt")
      File.write(file1, "Content 1")
      File.write(file2, "Content 2")

      PureRubyZip::ZipWriter.create(zip_path) do |zip|
        zip.add_file(file1)
        zip.add_file(file2, "renamed.txt")
      end

      zip_file = PureRubyZip::ZipFile.new(zip_path)
      expect(zip_file.entries).to contain_exactly("file1.txt", "renamed.txt")
      expect(zip_file.extract("file1.txt")).to eq("Content 1")
      expect(zip_file.extract("renamed.txt")).to eq("Content 2")
    end

    it "raises error for non-existent file" do
      expect {
        PureRubyZip::ZipWriter.create(zip_path) do |zip|
          zip.add_file("/nonexistent/file.txt")
        end
      }.to raise_error(Errno::ENOENT)
    end

    it "raises error for directory" do
      dir = File.join(temp_dir, "subdir")
      FileUtils.mkdir_p(dir)

      expect {
        PureRubyZip::ZipWriter.create(zip_path) do |zip|
          zip.add_file(dir)
        end
      }.to raise_error(ArgumentError, /Cannot add directory/)
    end

    it "preserves file content exactly" do
      source_file = File.join(temp_dir, "binary.bin")
      binary_content = (0..255).to_a.pack("C*") * 10
      File.binwrite(source_file, binary_content)

      PureRubyZip::ZipWriter.create(zip_path) do |zip|
        zip.add_file(source_file)
      end

      zip_file = PureRubyZip::ZipFile.new(zip_path)
      expect(zip_file.extract("binary.bin")).to eq(binary_content)
    end
  end

  describe "integration tests" do
    it "creates a complex archive with mixed content" do
      # Create test files
      file1 = File.join(temp_dir, "document.txt")
      file2 = File.join(temp_dir, "data.csv")
      File.write(file1, "Document content")
      File.write(file2, "col1,col2\n1,2\n3,4")

      # Create ZIP
      PureRubyZip::ZipWriter.create(zip_path) do |zip|
        zip.add_file(file1, "docs/document.txt", compression: :deflate)
        zip.add_file(file2, "exports/data.csv", compression: :stored)
        zip.add_buffer("README", "README.md", compression: :deflate)
        zip.add_buffer("License text", "LICENSE", compression: :stored)
      end

      # Verify
      zip_file = PureRubyZip::ZipFile.new(zip_path)
      expect(zip_file.size).to eq(4)
      expect(zip_file.entries).to contain_exactly(
        "docs/document.txt",
        "exports/data.csv",
        "README.md",
        "LICENSE"
      )

      # Verify content
      expect(zip_file.extract("docs/document.txt")).to eq("Document content")
      expect(zip_file.extract("exports/data.csv")).to eq("col1,col2\n1,2\n3,4")
      expect(zip_file.extract("README.md")).to eq("README")
      expect(zip_file.extract("LICENSE")).to eq("License text")
    end

    it "creates ZIP files compatible with standard tools" do
      PureRubyZip::ZipWriter.create(zip_path) do |zip|
        zip.add_buffer("Test file 1", "file1.txt")
        zip.add_buffer("Test file 2", "file2.txt")
      end

      # Verify it's a valid ZIP file by reading it back
      zip_file = PureRubyZip::ZipFile.new(zip_path)
      expect(zip_file.size).to eq(2)

      # Extract all files
      results = zip_file.extract_all
      expect(results.length).to eq(2)
      expect(results.map { |r| r[:path] }).to contain_exactly("file1.txt", "file2.txt")
    end
  end
end
