# PureRubyZip

A pure-Ruby ZIP file decompressor with no external dependencies. This library provides a clean API for reading and extracting ZIP archives, with comprehensive error handling and security protections.

## Features

- **Pure Ruby**: No external dependencies, works on any Ruby platform
- **DEFLATE Support**: Handles both stored (uncompressed) and DEFLATE compressed files
- **Security**: Built-in protections against path traversal and zip bombs
- **Comprehensive Error Handling**: Detailed error messages for debugging
- **Flexible API**: Extract single files, all files, or files matching patterns
- **Memory Efficient**: Optimized for performance with large archives
- **Well Tested**: Comprehensive test suite with RSpec

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'pure_ruby_zip'
```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install pure_ruby_zip

## Usage

### Command Line

Extract a ZIP file from the command line:

```bash
pure-ruby-zip archive.zip
```

### Library Usage

#### Basic Example

```ruby
require "pure_ruby_zip"

# Open a ZIP file
zip = PureRubyZip::ZipFile.new("archive.zip")

# List all files
puts zip.entries
# => ["file1.txt", "dir/file2.txt", "image.png"]

# Check if a file exists
zip.include?("file1.txt")
# => true

# Get number of entries
zip.size
# => 3

# Extract a single file to memory
data = zip.extract("file1.txt")
puts data
# => "contents of file1.txt"
```

#### Extract All Files

```ruby
# Extract all files to memory
files = zip.extract_all
files.each do |file|
  puts "#{file[:path]}: #{file[:data].length} bytes"
end

# Extract all files to disk (default: creates directory named after ZIP file)
zip.extract_to_disk

# Extract to a specific directory
zip.extract_to_disk("/path/to/output")
```

#### Pattern Matching

```ruby
# Extract files matching a pattern (returns array)
txt_files = zip.extract_matching(/\.txt$/)
txt_files.each do |file|
  puts "#{file[:path]}: #{file[:data]}"
end

# Extract files matching a pattern (with block)
zip.extract_matching(/\.jpg$/i) do |path, data|
  File.write("output/#{File.basename(path)}", data)
end
```

#### Iterate Over Files

```ruby
# Iterate over all entries
zip.each do |path, item|
  puts "#{path} (#{item.compressed_size} bytes compressed)"
  puts "  Compression: #{item.compression_method}"
  puts "  Directory: #{item.directory?}"
end

# Or use the enumerator
zip.each.with_index do |(path, item), index|
  puts "#{index + 1}. #{path}"
end
```

#### Access Individual Items

```ruby
# Get item by path
item = zip["dir/file.txt"]

# Check item properties
puts item.filename
puts item.compressed_size
puts item.uncompressed_size
puts item.compression_method  # 0 = stored, 8 = deflate
puts item.directory?
```

#### Error Handling

```ruby
begin
  zip = PureRubyZip::ZipFile.new("archive.zip")
  data = zip.extract("file.txt")
rescue PureRubyZip::FileNotFoundError => e
  puts "File not found in archive: #{e.message}"
rescue PureRubyZip::InvalidZipError => e
  puts "Invalid or corrupted ZIP file: #{e.message}"
rescue PureRubyZip::PathTraversalError => e
  puts "Security error: #{e.message}"
rescue PureRubyZip::ZipBombError => e
  puts "Potential zip bomb detected: #{e.message}"
rescue PureRubyZip::UnsupportedCompressionError => e
  puts "Unsupported compression method: #{e.message}"
rescue PureRubyZip::Error => e
  puts "Error: #{e.message}"
end
```

### Backward Compatibility

For backward compatibility with version 0.1.x, the following methods are aliased:

```ruby
zip.decompress_file("file.txt")           # alias for extract
zip.decompress_all_files                  # alias for extract_all
zip.decompress_all_files_to_disk          # alias for extract_to_disk
```

## Security

PureRubyZip includes several security features:

- **Path Traversal Protection**: Automatically validates file paths to prevent directory traversal attacks
- **Zip Bomb Protection**: Detects and prevents decompression of files with suspicious compression ratios (default max ratio: 100:1)
- **Size Limits**: Prevents decompression of files exceeding safe size limits (default: 1GB)
- **Input Validation**: Comprehensive validation of ZIP file structure and metadata

## Supported Compression Methods

- **Method 0**: Stored (no compression)
- **Method 8**: DEFLATE compression (RFC 1951)

## Limitations

- **Read-only**: This library only supports reading/extracting ZIP files, not creating them
- **No ZIP64**: Does not support ZIP64 extensions for very large archives
- **No Encryption**: Does not support encrypted ZIP files
- **Single-threaded**: Extraction is single-threaded

## Performance

While PureRubyZip prioritizes correctness and security over raw speed, it includes several performance optimizations:

- Byte array operations instead of string slicing
- Efficient bit-level operations for DEFLATE decompression
- Minimal memory allocation during decompression
- Binary file operations

For maximum performance with large archives, consider using a native extension like `rubyzip`.

## Development

After checking out the repo, run `bin/setup` to install dependencies:

```bash
git clone https://github.com/ehalferty/pure_ruby_zip.git
cd pure_ruby_zip
bin/setup
```

Run tests with:

```bash
bundle exec rake spec
```

Or run individual tests:

```bash
bundle exec rspec spec/pure_ruby_zip_spec.rb
```

Run the console for interactive experimentation:

```bash
bin/console
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/ehalferty/pure_ruby_zip.

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Make your changes and add tests
4. Run the test suite (`bundle exec rake spec`)
5. Commit your changes (`git commit -am 'Add some feature'`)
6. Push to the branch (`git push origin my-new-feature`)
7. Create a new Pull Request

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Credits

Created by Edward Halferty (me@edwardhalferty.com)

## Changelog

### Version 0.1.4
- Complete rewrite with comprehensive improvements
- Added security protections (path traversal, zip bomb detection)
- Improved performance (byte arrays, efficient operations)
- Added comprehensive error handling
- Enhanced API (entries, each, include?, [], extract_matching)
- Added full test suite with RSpec
- Improved documentation
- Removed bundler runtime dependency
- Updated to modern Ruby practices
