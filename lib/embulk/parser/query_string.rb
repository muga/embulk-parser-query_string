require "addressable/uri"

module Embulk
  module Parser

    class QueryString < ParserPlugin
      Plugin.register_parser("query_string", self)

      def self.transaction(config, &control)
        decoder_task = config.load_config(Java::LineDecoder::DecoderTask)

        task = {
          "decoder" => DataSource.from_java(decoder_task.dump),
          "strip_quote" => config.param("strip_quote", :bool, default: true),
          "strip_whitespace" => config.param("strip_whitespace", :bool, default: true),
          "capture" => config.param("capture", :string, default: nil),
        }

        columns = []
        schema = config.param("columns", :array, default: [])
        schema.each do |column|
          name = column["name"]
          type = column["type"].to_sym

          columns << Column.new(nil, name, type)
        end

        yield(task, columns)
      end

      def init
        @options = {
          strip_quote: task["strip_quote"],
          strip_whitespace: task["strip_whitespace"],
          capture: task["capture"],
        }

        @decoder = task.param("decoder", :hash).load_task(Java::LineDecoder::DecoderTask)
      end

      def run(file_input)
        decoder = Java::LineDecoder.new(file_input.to_java, @decoder)

        while decoder.nextFile
          while line = decoder.poll
            process_line(line)
          end
        end

        page_builder.finish
      end

      def self.parse(line, options = {})
        if options[:capture]
          line = line.match(options[:capture]).to_a[1] || ""
          # TODO: detect incorrect regexp given
        end

        return if line == ""

        line.strip! if options[:strip_whitespace]
        if options[:strip_quote]
          line = line[/\A(?:["'])?(.*?)(?:["'])?\z/, 1]
        end

        begin
          uri = Addressable::URI.parse("?#{line}")
          uri.query_values(Hash)
        rescue ArgumentError
          Embulk.logger.warn "Failed parse: #{line}"
          nil
        end
      end

      private

      def process_line(line)
        record = self.class.parse(line, @options)

        return unless record

        # NOTE: this conversion is needless afrer Embulk 0.6.13
        values = schema.map do |column|
          name = column.name
          value = record[name]

          next nil unless value

          begin
            case column.type
            when :long
              value.strip.empty? ? nil : Integer(value)
            when :timestamp
              value.strip.empty? ? nil : Time.parse(value)
            else
              value.to_s
            end
          rescue => e
            Embulk.logger.error "Cast failed '#{value}' as '#{column.type}' (key is '#{column.name}')"
            raise e
          end
        end

        page_builder.add(values)
      end
    end
  end
end
