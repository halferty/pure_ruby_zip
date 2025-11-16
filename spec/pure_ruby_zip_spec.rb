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
