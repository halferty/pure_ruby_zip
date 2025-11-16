require "pure_ruby_zip/version.rb"
require "fileutils"
require "pathname"

module PureRubyZip
  # Base error class for all PureRubyZip errors
  class Error < StandardError; end

  # Raised when the ZIP file format is invalid or corrupted
  class InvalidZipError < Error; end

  # Raised when a file is not found in the ZIP archive
  class FileNotFoundError < Error; end

  # Raised when path traversal is detected
  class PathTraversalError < Error; end

  # Raised when ZIP bomb is detected
  class ZipBombError < Error; end

  # Raised when an unsupported compression method is encountered
  class UnsupportedCompressionError < Error; end

  # Maximum decompression ratio to prevent zip bombs (default: 100)
  MAX_DECOMPRESSION_RATIO = 100

  # Maximum decompressed size in bytes (default: 1GB)
  MAX_DECOMPRESSED_SIZE = 1024 * 1024 * 1024

  # DEFLATE algorithm constants
  CODE_LENGTH_CODES_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15].freeze
  LENGTH_EXTRA_BITS = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0].freeze
  LENGTH_BASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163,
    195, 227, 258].freeze
  DISTANCE_EXTRA_BITS = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13,
    13].freeze
  DISTANCE_BASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049,
    3073, 4097, 6145, 8193, 12289, 16385, 24577].freeze

  # ZIP file signatures
  EOCD_SIGNATURE = "\x50\x4b\x05\x06".freeze
  CENTRAL_DIR_SIGNATURE = "\x50\x4b\x01\x02".freeze
  LOCAL_FILE_SIGNATURE = "\x50\x4b\x03\x04".freeze
  # Bitstream reader for reading individual bits from compressed data
  # Performance optimized to use byte array instead of string slicing
  class Bitstream
    # Initialize a bitstream from binary data
    # @param data [String] binary data to read from
    def initialize(data)
      raise ArgumentError, "Data cannot be nil" if data.nil?
      @data = data.bytes # Convert to byte array for better performance
      @byte_index = 0
      @bit_index = 0
    end

    # Read a single bit from the stream
    # @return [Boolean] true if bit is 1, false if bit is 0
    # @raise [InvalidZipError] if attempting to read past end of data
    def read_bit
      raise InvalidZipError, "Unexpected end of compressed data" if @byte_index >= @data.length

      current_byte = @data[@byte_index]
      result = ((current_byte >> @bit_index) & 1) == 1

      @bit_index += 1
      if @bit_index == 8
        @byte_index += 1
        @bit_index = 0
      end

      result
    end

    # Read multiple bits as an integer (little-endian)
    # @param n_bits [Integer] number of bits to read
    # @return [Integer] the value read
    # @raise [ArgumentError] if n_bits is negative or too large
    def read_int(n_bits)
      raise ArgumentError, "Number of bits must be positive" if n_bits < 0
      raise ArgumentError, "Number of bits too large" if n_bits > 32

      result = 0
      n_bits.times { |i| result |= (read_bit ? 1 : 0) << i }
      result
    end

    # Check if there are more bytes available
    # @return [Boolean] true if more data is available
    def more_data?
      @byte_index < @data.length
    end
  end
  # DEFLATE decompressor implementing Huffman decoding
  class ZipDecompressor
    # Decode a single symbol from the Huffman tree
    # @param tree [Hash] Huffman tree mapping bit patterns to symbols
    # @param file_bitstream [Bitstream] bitstream to read from
    # @return [Integer] decoded symbol
    # @raise [InvalidZipError] if invalid Huffman code is encountered
    def decode_symbol(tree, file_bitstream)
      bits = []
      max_iterations = 15 # Huffman codes are typically max 15 bits

      max_iterations.times do
        bit = file_bitstream.read_bit
        bits << bit
        key = bits.map { |b| b ? "1" : "0" }.join("")
        return tree[key] if tree.key?(key)
      end

      raise InvalidZipError, "Invalid Huffman code encountered"
    end

    # Inflate (decompress) a block of DEFLATE data
    # @param litlen_tree [Hash] literal/length Huffman tree
    # @param dist_tree [Hash] distance Huffman tree
    # @param file_data [String] accumulated decompressed data
    # @param file_bitstream [Bitstream] bitstream to read from
    # @return [String] decompressed data
    # @raise [ZipBombError] if decompressed data exceeds safe limits
    def inflate_block_data(litlen_tree, dist_tree, file_data, file_bitstream)
      # Use array for better performance with many appends
      data_bytes = file_data.bytes
      max_size = MAX_DECOMPRESSED_SIZE

      loop do
        sym = decode_symbol(litlen_tree, file_bitstream)

        if sym < 256
          # Literal byte
          data_bytes << sym
        elsif sym == 256
          # End of block
          return data_bytes.pack("C*")
        else
          # Length/distance pair for LZ77 back-reference
          sym -= 257
          raise InvalidZipError, "Invalid length symbol: #{sym}" if sym >= LENGTH_BASE.length

          length = file_bitstream.read_int(LENGTH_EXTRA_BITS[sym]) + LENGTH_BASE[sym]
          dist_sym = decode_symbol(dist_tree, file_bitstream)
          raise InvalidZipError, "Invalid distance symbol: #{dist_sym}" if dist_sym >= DISTANCE_BASE.length

          dist = file_bitstream.read_int(DISTANCE_EXTRA_BITS[dist_sym]) + DISTANCE_BASE[dist_sym]

          # Validate distance
          raise InvalidZipError, "Invalid back-reference distance: #{dist}" if dist > data_bytes.length

          # Copy bytes from earlier in the output
          length.times do
            data_bytes << data_bytes[-dist]
          end
        end

        # Check for zip bomb
        if data_bytes.length > max_size
          raise ZipBombError, "Decompressed data exceeds maximum safe size (#{max_size} bytes)"
        end
      end
    end
    # Build Huffman tree from bit lengths using canonical Huffman algorithm
    # @param bit_lengths [Array<Integer>] bit length for each symbol
    # @return [Hash] Huffman tree mapping bit patterns (strings) to symbols
    def bit_lengths_to_tree(bit_lengths)
      return {} if bit_lengths.empty?

      max_bits = bit_lengths.max
      return {} if max_bits.nil? || max_bits == 0

      # Count symbols at each bit length
      bitlen_counts = Array.new(max_bits + 1, 0)
      bit_lengths.each { |length| bitlen_counts[length] += 1 if length > 0 }

      # Calculate first code for each bit length
      next_code = Array.new(max_bits + 1, 0)
      (2..max_bits).each do |i|
        next_code[i] = (next_code[i - 1] + bitlen_counts[i - 1]) << 1
      end

      # Assign codes to symbols
      tree = {}
      bit_lengths.each_with_index do |length, symbol|
        if length > 0
          code = next_code[length].to_s(2).rjust(length, "0")
          tree[code] = symbol
          next_code[length] += 1
        end
      end

      tree
    end

    # Decode an uncompressed (stored) block
    # @param file_data [String] accumulated output (unused for this block type)
    # @param file_bitstream [Bitstream] bitstream to read from
    # @return [String] uncompressed data
    def decode_uncompressed_block(file_data, file_bitstream)
      # Skip to byte boundary
      file_bitstream.read_int(5) if file_bitstream.instance_variable_get(:@bit_index) > 0

      # Read length and its one's complement
      length = file_bitstream.read_int(16)
      nlen = file_bitstream.read_int(16)

      # Verify length complement
      raise InvalidZipError, "Uncompressed block length check failed" if (length ^ nlen) != 0xFFFF

      # Read uncompressed bytes
      bytes = Array.new(length) { file_bitstream.read_int(8) }
      bytes.pack("C*")
    end

    # Decode a block with fixed Huffman codes
    # @param file_data [String] accumulated decompressed data
    # @param file_bitstream [Bitstream] bitstream to read from
    # @return [String] decompressed data
    def decode_fixed_huffman_compressed_block(file_data, file_bitstream)
      # Fixed Huffman code bit lengths as per RFC 1951
      litlen_bit_lengths = [8] * 144 + [9] * 112 + [7] * 24 + [8] * 8
      litlen_tree = bit_lengths_to_tree(litlen_bit_lengths)

      dist_bit_lengths = [5] * 32
      dist_tree = bit_lengths_to_tree(dist_bit_lengths)

      inflate_block_data(litlen_tree, dist_tree, file_data, file_bitstream)
    end

    # Decode a block with dynamic Huffman codes
    # @param file_data [String] accumulated decompressed data
    # @param file_bitstream [Bitstream] bitstream to read from
    # @return [String] decompressed data
    def decode_dynamic_huffman_compressed_block(file_data, file_bitstream)
      # Read header
      hlit = file_bitstream.read_int(5) + 257
      hdist = file_bitstream.read_int(5) + 1
      hclen = file_bitstream.read_int(4) + 4

      # Read code length alphabet
      code_length_bit_lengths = Array.new(19, 0)
      hclen.times { |i| code_length_bit_lengths[CODE_LENGTH_CODES_ORDER[i]] = file_bitstream.read_int(3) }
      code_length_tree = bit_lengths_to_tree(code_length_bit_lengths)

      # Decode bit lengths for literal/length and distance alphabets
      bit_lengths = []
      total_lengths = hlit + hdist

      while bit_lengths.length < total_lengths
        sym = decode_symbol(code_length_tree, file_bitstream)

        case sym
        when 0..15
          # Literal bit length
          bit_lengths << sym
        when 16
          # Repeat previous bit length 3-6 times
          raise InvalidZipError, "Code 16 with no previous length" if bit_lengths.empty?
          prev_length = bit_lengths.last
          repeat_count = file_bitstream.read_int(2) + 3
          bit_lengths.concat([prev_length] * repeat_count)
        when 17
          # Repeat 0 for 3-10 times
          repeat_count = file_bitstream.read_int(3) + 3
          bit_lengths.concat([0] * repeat_count)
        when 18
          # Repeat 0 for 11-138 times
          repeat_count = file_bitstream.read_int(7) + 11
          bit_lengths.concat([0] * repeat_count)
        else
          raise InvalidZipError, "Invalid code length symbol: #{sym}"
        end
      end

      # Split into literal/length and distance trees
      litlen_tree = bit_lengths_to_tree(bit_lengths[0...hlit])
      dist_tree = bit_lengths_to_tree(bit_lengths[hlit...total_lengths])

      inflate_block_data(litlen_tree, dist_tree, file_data, file_bitstream)
    end

    # Decode a complete DEFLATE compressed file
    # @param file_bitstream [Bitstream] bitstream to read from
    # @return [String] fully decompressed data
    def decode_zipped_file(file_bitstream)
      file_data = ""
      is_last_block = false

      until is_last_block
        is_last_block = file_bitstream.read_bit
        block_type = file_bitstream.read_int(2)

        file_data = case block_type
        when 0
          # Uncompressed block
          file_data + decode_uncompressed_block(file_data, file_bitstream)
        when 1
          # Fixed Huffman
          decode_fixed_huffman_compressed_block(file_data, file_bitstream)
        when 2
          # Dynamic Huffman
          decode_dynamic_huffman_compressed_block(file_data, file_bitstream)
        else
          raise InvalidZipError, "Invalid block type: #{block_type}"
        end
      end

      file_data
    end
  end
  # Helper methods for reading ZIP file structures
  module ZipHelpers
    # Read a little-endian integer from file
    # @param file [File] file to read from
    # @param bytes [Integer] number of bytes to read
    # @return [Integer] the integer value
    # @raise [InvalidZipError] if unable to read required bytes
    def read_int(file, bytes)
      data = file.read(bytes)
      raise InvalidZipError, "Unexpected end of file" if data.nil? || data.length < bytes

      # Convert to little-endian integer
      data.bytes.each_with_index.reduce(0) { |acc, (byte, i)| acc + (byte << (8 * i)) }
    end

    # Search for a signature string in the file
    # @param file [File] file to search in
    # @param signature [String] signature bytes to find
    # @raise [InvalidZipError] if signature not found before EOF
    def find_signature(file, signature)
      buffer = ""
      sig_len = signature.length

      loop do
        byte = file.read(1)
        raise InvalidZipError, "Signature #{signature.bytes.inspect} not found" if byte.nil?

        buffer = buffer.length >= sig_len ? buffer[1..-1] + byte : buffer + byte
        return if buffer == signature
      end
    end

    # Skip specified number of bytes in file
    # @param file [File] file to skip in
    # @param bytes [Integer] number of bytes to skip
    # @raise [InvalidZipError] if unable to skip required bytes
    def skip(file, bytes)
      data = file.read(bytes)
      raise InvalidZipError, "Unexpected end of file while skipping" if data.nil? || data.length < bytes
      data
    end

    # Validate that a file path doesn't attempt directory traversal
    # @param path [String] path to validate
    # @raise [PathTraversalError] if path attempts traversal
    def validate_safe_path(path)
      # Check for other potentially dangerous patterns first (before calling Pathname)
      if path.include?("\0")
        raise PathTraversalError, "Invalid characters in path: null byte detected"
      end

      if path.include?("\\")
        raise PathTraversalError, "Invalid characters in path: backslash detected"
      end

      # Normalize path and check for directory traversal
      begin
        normalized = Pathname.new(path).cleanpath.to_s
      rescue ArgumentError => e
        raise PathTraversalError, "Invalid path: #{e.message}"
      end

      # Check for absolute paths or parent directory references
      if normalized.start_with?("/") || normalized.start_with?("..") || normalized.include?("/../")
        raise PathTraversalError, "Path traversal detected: #{path}"
      end

      normalized
    end
  end
  # Represents a single file entry in a ZIP archive
  class ZipFileItem
    include ZipHelpers

    attr_reader :filename, :offset, :compressed_size, :uncompressed_size, :compression_method

    # Initialize a ZIP file item
    # @param filename [String] name of the file in the archive
    # @param offset [Integer] offset to local file header in ZIP file
    # @param compressed_size [Integer] size of compressed data
    # @param uncompressed_size [Integer] size of uncompressed data
    # @param compression_method [Integer] compression method (0=store, 8=deflate)
    def initialize(filename, offset, compressed_size, uncompressed_size, compression_method)
      @filename = filename
      @offset = offset
      @compressed_size = compressed_size
      @uncompressed_size = uncompressed_size
      @compression_method = compression_method
    end

    # Read compressed data for this file
    # @param zipfile [File] the ZIP file to read from
    # @return [String] compressed file data
    # @raise [InvalidZipError] if local header doesn't match expectations
    def read_compressed_data(zipfile)
      zipfile.seek @offset

      # Verify local file header signature (4 bytes)
      signature = zipfile.read(4)
      raise InvalidZipError, "Invalid local file header signature" if signature != LOCAL_FILE_SIGNATURE

      # Read local file header structure:
      # Version needed (2), flags (2), compression method (2)
      skip zipfile, 2  # version needed to extract
      skip zipfile, 2  # general purpose bit flag
      compression = read_int zipfile, 2  # compression method

      # Verify compression method matches
      unless compression == @compression_method
        raise InvalidZipError, "Compression method mismatch: expected #{@compression_method}, got #{compression}"
      end

      # Skip: last mod time (2), last mod date (2), crc-32 (4)
      skip zipfile, 2  # last mod file time
      skip zipfile, 2  # last mod file date
      skip zipfile, 4  # crc-32

      # Read sizes
      compressed_size = read_int zipfile, 4
      uncompressed_size = read_int zipfile, 4

      # Read lengths
      filename_length = read_int zipfile, 2
      extra_length = read_int zipfile, 2

      # Skip filename and extra field
      skip zipfile, filename_length if filename_length > 0
      skip zipfile, extra_length if extra_length > 0

      # Read compressed data - use the size from central directory if available
      size_to_read = @compressed_size > 0 ? @compressed_size : compressed_size
      data = zipfile.read(size_to_read)
      raise InvalidZipError, "Unable to read compressed data (expected #{size_to_read} bytes)" if data.nil? || data.length < size_to_read

      data
    end

    # Decompress DEFLATE compressed data
    # @param zipfile [File] the ZIP file to read from
    # @return [String] decompressed data
    # @raise [ZipBombError] if decompression ratio is suspicious
    def decompress_deflate(zipfile)
      compressed_data = read_compressed_data(zipfile)

      # Check compression ratio to detect zip bombs
      if @uncompressed_size > 0 && @compressed_size > 0
        ratio = @uncompressed_size.to_f / @compressed_size
        if ratio > MAX_DECOMPRESSION_RATIO
          raise ZipBombError, "Suspicious compression ratio: #{ratio.round(2)} (max: #{MAX_DECOMPRESSION_RATIO})"
        end
      end

      bitstream = Bitstream.new(compressed_data)
      decompressor = ZipDecompressor.new
      decompressed = decompressor.decode_zipped_file(bitstream)

      # Verify decompressed size matches expected
      if @uncompressed_size > 0 && decompressed.length != @uncompressed_size
        raise InvalidZipError, "Decompressed size mismatch: expected #{@uncompressed_size}, got #{decompressed.length}"
      end

      decompressed
    end

    # Read uncompressed (stored) data
    # @param zipfile [File] the ZIP file to read from
    # @return [String] file data
    def read_stored_data(zipfile)
      read_compressed_data(zipfile)
    end

    # Get decompressed data for this file
    # @param zipfile [File] the ZIP file to read from
    # @return [String] decompressed file data
    # @raise [UnsupportedCompressionError] if compression method is not supported
    def get_decompressed_data(zipfile)
      case @compression_method
      when 0
        # Stored (no compression)
        read_stored_data(zipfile)
      when 8
        # DEFLATE compression
        decompress_deflate(zipfile)
      else
        raise UnsupportedCompressionError, "Unsupported compression method: #{@compression_method}"
      end
    end

    # Check if this is a directory entry
    # @return [Boolean] true if this is a directory
    def directory?
      @filename.end_with?("/")
    end
  end
  # Main class for reading ZIP archives
  class ZipFile
    include ZipHelpers

    attr_reader :filename, :items

    # Initialize and parse a ZIP file
    # @param filename [String] path to the ZIP file
    # @raise [Errno::ENOENT] if file doesn't exist
    # @raise [InvalidZipError] if file is not a valid ZIP
    def initialize(filename)
      raise Errno::ENOENT, "File not found: #{filename}" unless File.exist?(filename)
      raise ArgumentError, "Cannot read directory as ZIP file: #{filename}" if File.directory?(filename)

      @filename = filename
      @items = {}
      parse_zip_file
    end

    # List all files in the archive
    # @return [Array<String>] array of filenames
    def entries
      @items.keys
    end

    # Get a specific file item
    # @param path [String] path to the file in the archive
    # @return [ZipFileItem] the file item
    # @raise [FileNotFoundError] if file not found in archive
    def [](path)
      item = @items[path]
      raise FileNotFoundError, "File not found in archive: #{path}" unless item
      item
    end

    # Check if a file exists in the archive
    # @param path [String] path to check
    # @return [Boolean] true if file exists
    def include?(path)
      @items.key?(path)
    end

    # Get number of entries in the archive
    # @return [Integer] number of entries
    def size
      @items.size
    end

    # Iterate over all entries
    # @yield [path, item] yields path and ZipFileItem for each entry
    # @return [Enumerator] if no block given
    def each(&block)
      return @items.each(&block) if block_given?
      @items.each
    end

    # Extract a single file by path
    # @param path [String] path to the file in the archive
    # @return [String] decompressed file data
    # @raise [FileNotFoundError] if file not found
    def extract(path)
      item = self[path]
      File.open(@filename, "rb") do |file|
        item.get_decompressed_data(file)
      end
    end

    # Alias for backward compatibility
    alias_method :decompress_file, :extract

    # Extract all files and return as array of hashes
    # @return [Array<Hash>] array of {path:, data:} hashes
    def extract_all
      results = []
      File.open(@filename, "rb") do |file|
        @items.each do |path, item|
          next if item.directory?

          results << {
            path: path,
            data: item.get_decompressed_data(file)
          }
        end
      end
      results
    end

    # Alias for backward compatibility
    alias_method :decompress_all_files, :extract_all

    # Extract all files to a directory
    # @param output_dir [String, nil] directory to extract to (default: ZIP filename without extension)
    # @return [Array<String>] array of extracted file paths
    # @raise [PathTraversalError] if any file attempts path traversal
    def extract_to_disk(output_dir = nil)
      # Determine output directory
      if output_dir.nil?
        dir_of_zip = File.dirname(@filename)
        base_name = File.basename(@filename, ".*")
        output_dir = File.join(dir_of_zip, base_name)
      end

      # Create output directory
      FileUtils.mkdir_p(output_dir) unless Dir.exist?(output_dir)

      extracted_paths = []

      File.open(@filename, "rb") do |file|
        @items.each do |path, item|
          # Validate path for security
          safe_path = validate_safe_path(path)
          output_path = File.join(output_dir, safe_path)

          if item.directory?
            # Create directory
            FileUtils.mkdir_p(output_path)
          else
            # Create parent directories
            FileUtils.mkdir_p(File.dirname(output_path))

            # Extract file
            data = item.get_decompressed_data(file)
            File.open(output_path, "wb") do |output_file|
              output_file.write(data)
            end

            extracted_paths << output_path
          end
        end
      end

      extracted_paths
    end

    # Alias for backward compatibility
    alias_method :decompress_all_files_to_disk, :extract_to_disk

    # Extract files matching a pattern
    # @param pattern [String, Regexp] pattern to match against filenames
    # @yield [path, data] if block given, yields path and data instead of returning
    # @return [Array<Hash>] array of {path:, data:} hashes (if no block given)
    def extract_matching(pattern)
      regex = pattern.is_a?(Regexp) ? pattern : Regexp.new(pattern)
      results = []

      File.open(@filename, "rb") do |file|
        @items.each do |path, item|
          next unless path.match?(regex)
          next if item.directory?

          data = item.get_decompressed_data(file)

          if block_given?
            yield path, data
          else
            results << {path: path, data: data}
          end
        end
      end

      results unless block_given?
    end

    private

    # Find End of Central Directory record
    # @param file [File] file to search in
    def find_eocd(file)
      find_signature(file, EOCD_SIGNATURE)
    end

    # Find Central Directory record
    # @param file [File] file to search in
    def find_central_directory(file)
      find_signature(file, CENTRAL_DIR_SIGNATURE)
    end

    # Parse the ZIP file and build the items hash
    def parse_zip_file
      File.open(@filename, "rb") do |file|
        # Find EOCD and read number of entries
        find_eocd(file)
        skip file, 6
        num_entries = read_int(file, 2)

        raise InvalidZipError, "Invalid number of entries: #{num_entries}" if num_entries < 0

        # Rewind and read central directory
        file.seek(0)

        num_entries.times do
          find_central_directory(file)

          # Read central directory header (46 bytes total + variable filename/extra/comment)
          skip file, 6 # version made by (2), version needed (2), flags (2)
          compression_method = read_int(file, 2)
          skip file, 4 # mod time (2), mod date (2)
          skip file, 4 # crc32
          compressed_size = read_int(file, 4)
          uncompressed_size = read_int(file, 4)
          filename_length = read_int(file, 2)
          extra_length = read_int(file, 2)
          comment_length = read_int(file, 2)
          skip file, 2 # disk number start
          skip file, 2 # internal file attributes
          skip file, 4 # external file attributes
          file_offset = read_int(file, 4)

          # Read filename (exactly filename_length bytes)
          filename_data = file.read(filename_length)
          raise InvalidZipError, "Unable to read filename" if filename_data.nil? || filename_data.length < filename_length

          # Convert to string and force encoding to UTF-8 (ZIP spec allows UTF-8)
          filename = filename_data.force_encoding('UTF-8')

          # Skip extra field and comment
          skip(file, extra_length) if extra_length > 0
          skip(file, comment_length) if comment_length > 0

          # Create file item
          item = ZipFileItem.new(
            filename,
            file_offset,
            compressed_size,
            uncompressed_size,
            compression_method
          )

          @items[filename] = item
        end
      end
    end
  end
end
