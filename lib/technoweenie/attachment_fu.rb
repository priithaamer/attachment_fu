require 'technoweenie/attachment_fu/backends'
require 'technoweenie/attachment_fu/processors'

module Technoweenie # :nodoc:
  module AttachmentFu # :nodoc:
    @@default_processors = %w(image_science rmagick mini_magick gd2 core_image)
    @@tempfile_path      = File.join(Rails.root.to_s, 'tmp', 'attachment_fu')
    @@content_types      = [
      'image/jpeg',
      'image/pjpeg',
      'image/jpg',
      'image/gif',
      'image/png',
      'image/x-png',
      'image/jpg',
      'image/x-ms-bmp',
      'image/bmp',
      'image/x-bmp',
      'image/x-bitmap',
      'image/x-xbitmap',
      'image/x-win-bitmap',
      'image/x-windows-bmp',
      'image/ms-bmp',
      'application/bmp',
      'application/x-bmp',
      'application/x-win-bitmap',
      'application/preview',
      'image/jp_',
      'application/jpg',
      'application/x-jpg',
      'image/pipeg',
      'image/vnd.swiftview-jpeg',
      'image/x-xbitmap',
      'application/png',
      'application/x-png',
      'image/gi_',
      'image/x-citrix-pjpeg'
    ]
    mattr_reader :content_types, :tempfile_path, :default_processors
    mattr_writer :tempfile_path

    class ThumbnailError < StandardError;  end
    class AttachmentError < StandardError; end

    module ActMethods
      # Options:
      # *  <tt>:content_type</tt> - Allowed content types.  Allows all by default.  Use :image to allow all standard image types.
      # *  <tt>:min_size</tt> - Minimum size allowed.  1 byte is the default.
      # *  <tt>:max_size</tt> - Maximum size allowed.  1.megabyte is the default.
      # *  <tt>:size</tt> - Range of sizes allowed.  (1..1.megabyte) is the default.  This overrides the :min_size and :max_size options.
      # *  <tt>:resize_to</tt> - Used by RMagick to resize images.  Pass either an array of width/height, or a geometry string.
      # *  <tt>:thumbnails</tt> - Specifies a set of thumbnails to generate.  This accepts a hash of filename suffixes and RMagick resizing options.
      # *  <tt>:thumbnail_class</tt> - Set what class to use for thumbnails.  This attachment class is used by default.
      # *  <tt>:path_prefix</tt> - path to store the uploaded files.  Uses public/#{table_name} by default for the filesystem, and just #{table_name}
      #      for the S3 backend.  Setting this sets the :storage to :file_system.

      # *  <tt>:storage</tt> - Use :file_system to specify the attachment data is stored with the file system.  Defaults to :db_system.
      # *  <tt>:cloundfront</tt> - Set to true if you are using S3 storage and want to serve the files through CloudFront.  You will need to
      #      set a distribution domain in the amazon_s3.yml config file. Defaults to false
      # *  <tt>:bucket_key</tt> - Use this to specify a different bucket key other than :bucket_name in the amazon_s3.yml file.  This allows you to use
      #      different buckets for different models. An example setting would be :image_bucket and the you would need to define the name of the corresponding
      #      bucket in the amazon_s3.yml file.

      # *  <tt>:keep_profile</tt> By default image EXIF data will be stripped to minimize image size. For small thumbnails this proivides important savings. Picture quality is not affected. Set to false if you want to keep the image profile as is. ImageScience will allways keep EXIF data.
      #
      # Examples:
      #   has_attachment :max_size => 1.kilobyte
      #   has_attachment :size => 1.megabyte..2.megabytes
      #   has_attachment :content_type => 'application/pdf'
      #   has_attachment :content_type => ['application/pdf', 'application/msword', 'text/plain']
      #   has_attachment :content_type => :image, :resize_to => [50,50]
      #   has_attachment :content_type => ['application/pdf', :image], :resize_to => 'x50'
      #   has_attachment :thumbnails => { :thumb => [50, 50], :geometry => 'x50' }
      #   has_attachment :storage => :file_system, :path_prefix => 'public/files'
      #   has_attachment :storage => :file_system, :path_prefix => 'public/files',
      #     :content_type => :image, :resize_to => [50,50]
      #   has_attachment :storage => :file_system, :path_prefix => 'public/files',
      #     :thumbnails => { :thumb => [50, 50], :geometry => 'x50' }
      #   has_attachment :storage => :s3
      def has_attachment(options = {})
        # this allows you to redefine the acts' options for each subclass, however
        options[:min_size]         ||= 1
        options[:max_size]         ||= 1.megabyte
        options[:size]             ||= (options[:min_size]..options[:max_size])
        options[:thumbnails]       ||= {}
        options[:thumbnail_class]  ||= self
        options[:s3_access]        ||= :public_read
        options[:cloudfront]       ||= false
        options[:content_type] = [options[:content_type]].flatten.collect! { |t| t == :image ? Technoweenie::AttachmentFu.content_types : t }.flatten unless options[:content_type].nil?

        unless options[:thumbnails].is_a?(Hash)
          raise ArgumentError, ":thumbnails option should be a hash: e.g. :thumbnails => { :foo => '50x50' }"
        end

        extend ClassMethods unless (class << self; included_modules; end).include?(ClassMethods)
        include InstanceMethods unless included_modules.include?(InstanceMethods)

        parent_options = attachment_options || {}
        # doing these shenanigans so that #attachment_options is available to processors and backends
        self.attachment_options = options

        attr_accessor :thumbnail_resize_options

        attachment_options[:storage]     ||= (attachment_options[:file_system_path] || attachment_options[:path_prefix]) ? :file_system : :db_file
        attachment_options[:storage]     ||= parent_options[:storage]
        attachment_options[:path_prefix] ||= attachment_options[:file_system_path]
        if attachment_options[:path_prefix].nil?
          attachment_options[:path_prefix] = case attachment_options[:storage]
            when :s3 then table_name
            when :cloud_files then table_name
            else File.join("public", table_name)
          end
        end
        attachment_options[:path_prefix]   = attachment_options[:path_prefix][1..-1] if options[:path_prefix].first == '/'

        association_options = { :foreign_key => 'parent_id' }
        if attachment_options[:association_options]
          association_options.merge!(attachment_options[:association_options])
        end
        with_options(association_options) do |m|
          m.has_many   :thumbnails, :class_name => "::#{attachment_options[:thumbnail_class]}"
          m.belongs_to :parent, :class_name => "::#{base_class}" unless options[:thumbnails].empty?
        end

        storage_mod = Technoweenie::AttachmentFu::Backends.const_get("#{options[:storage].to_s.classify}Backend")
        include storage_mod unless included_modules.include?(storage_mod)

        case attachment_options[:processor]
        when :none, nil
          processors = Technoweenie::AttachmentFu.default_processors.dup
          begin
            if processors.any?
              attachment_options[:processor] = processors.first
              require "technoweenie/attachment_fu/processors/#{attachment_options[:processor].to_s}_processor"
              processor_mod = Technoweenie::AttachmentFu::Processors.const_get("#{attachment_options[:processor].to_s.classify}Processor")
              include processor_mod unless included_modules.include?(processor_mod)
            end
          rescue Object, Exception
            raise unless load_related_exception?($!)

            processors.shift
            retry
          end
        else
          begin
            require "technoweenie/attachment_fu/processors/#{attachment_options[:processor].to_s}_processor"
            processor_mod = Technoweenie::AttachmentFu::Processors.const_get("#{attachment_options[:processor].to_s.classify}Processor")
            include processor_mod unless included_modules.include?(processor_mod)
          rescue Object, Exception
            raise unless load_related_exception?($!)

            puts "Problems loading #{options[:processor]}Processor: #{$!}"
          end
        end unless parent_options[:processor] # Don't let child override processor
      end

      def load_related_exception?(e) #:nodoc: implementation specific
        case
        when e.kind_of?(LoadError), e.kind_of?(MissingSourceFile), $!.class.name == "CompilationError"
          # We can't rescue CompilationError directly, as it is part of the RubyInline library.
          # We must instead rescue RuntimeError, and check the class' name.
          true
        else
          false
        end
      end
      private :load_related_exception?
    end

    module ClassMethods
      delegate :content_types, :to => Technoweenie::AttachmentFu

      # Performs common validations for attachment models.
      def validates_as_attachment
        validates_presence_of :size, :content_type, :filename
        validate              :attachment_attributes_valid?
      end

      # Returns true or false if the given content type is recognized as an image.
      def image?(content_type)
        content_types.include?(content_type)
      end

      def self.extended(base)
        base.class_attribute :attachment_options
        base.before_destroy :destroy_thumbnails
        base.before_validation :set_size_from_temp_path
        base.after_save :after_process_attachment
        base.after_destroy :destroy_file
        base.after_validation :process_attachment
        if defined?(::ActiveSupport::Callbacks)
          base.define_callbacks :resize, :kind => :after
          base.define_callbacks :thumbnail_saved, :kind => :before
        end
      end

      unless defined?(::ActiveSupport::Callbacks)
        # Callback after an image has been resized.
        #
        #   class Foo < ActiveRecord::Base
        #     acts_as_attachment
        #     after_resize do |record, img|
        #       record.aspect_ratio = img.columns.to_f / img.rows.to_f
        #     end
        #   end
        def after_resize(&block)
          write_inheritable_array(:after_resize, [block])
        end

        # Callback before a thumbnail is saved.  Use this to pass any necessary extra attributes that may be required.
        #
        #   class Foo < ActiveRecord::Base
        #     acts_as_attachment
        #     before_thumbnail_saved do |thumbnail|
        #       record = thumbnail.parent
        #       ...
        #     end
        #   end
        def before_thumbnail_saved(&block)
          write_inheritable_array(:before_thumbnail_saved, [block])
        end
      end

      # Get the thumbnail class, which is the current attachment class by default.
      # Configure this with the :thumbnail_class option.
      def thumbnail_class
        attachment_options[:thumbnail_class] = attachment_options[:thumbnail_class].constantize unless attachment_options[:thumbnail_class].is_a?(Class)
        attachment_options[:thumbnail_class]
      end

      # Copies the given file path to a new tempfile, returning the closed tempfile.
      def copy_to_temp_file(file, temp_base_name)
        Tempfile.new(temp_base_name, Technoweenie::AttachmentFu.tempfile_path).tap do |tmp|
          tmp.close
          FileUtils.cp file, tmp.path
        end
      end

      # Writes the given data to a new tempfile, returning the closed tempfile.
      def write_to_temp_file(data, temp_base_name)
        Tempfile.new(temp_base_name, Technoweenie::AttachmentFu.tempfile_path).tap do |tmp|
          tmp.binmode
          tmp.write data
          tmp.close
        end
      end
    end

    module InstanceMethods
      def self.included(base)
        if base.respond_to?(:define_callbacks)
          base.class_eval do
            define_callbacks :resize, :attachment_saved, :kind => :after
            define_callbacks :thumbnail_saved, :kind => :before
          end
        end
      end

      # Checks whether the attachment's content type is an image content type
      def image?
        self.class.image?(content_type)
      end

      # Returns true/false if an attachment is thumbnailable.  A thumbnailable attachment has an image content type and the parent_id attribute.
      def thumbnailable?
        image? && respond_to?(:parent_id) && parent_id.nil?
      end

      # Returns the class used to create new thumbnails for this attachment.
      def thumbnail_class
        self.class.thumbnail_class
      end

      # Gets the thumbnail name for a filename.  'foo.jpg' becomes 'foo_thumbnail.jpg'
      def thumbnail_name_for(thumbnail = nil)
        return filename if thumbnail.blank?
        ext = nil
        basename = filename.gsub(/\.\w+$/) do |s|
          ext = s; ''
        end
        # ImageScience doesn't create gif thumbnails, only pngs
        ext.sub!(/gif$/, 'png') if attachment_options[:processor] == "ImageScience"
        "#{basename}_#{thumbnail}#{ext}"
      end

      # Creates or updates the thumbnail for the current attachment.
      def create_or_update_thumbnail(temp_file, file_name_suffix, *size)
        thumbnailable? || raise(ThumbnailError.new("Can't create a thumbnail if the content type is not an image or there is no parent_id column"))
        find_or_initialize_thumbnail(file_name_suffix).tap do |thumb|
          thumb.temp_paths.unshift temp_file
          thumb.send(:'attributes=', {
            :content_type             => content_type,
            :filename                 => thumbnail_name_for(file_name_suffix),
            :thumbnail_resize_options => size
          }, false)
          callback_with_args :before_thumbnail_saved, thumb
          thumb.save!
        end
      end

      # Sets the content type.
      def content_type=(new_type)
        write_attribute :content_type, new_type.to_s.strip
      end

      # Sanitizes a filename.
      def filename=(new_name)
        write_attribute :filename, sanitize_filename(new_name)
      end

      # Returns the width/height in a suitable format for the image_tag helper: (100x100)
      def image_size
        [width.to_s, height.to_s] * 'x'
      end

      # Returns true if the attachment data will be written to the storage system on the next save
      def save_attachment?
        File.file?(temp_path.to_s)
      end

      # nil placeholder in case this field is used in a form.
      def uploaded_data() nil; end

      # This method handles the uploaded file object.  If you set the field name to uploaded_data, you don't need
      # any special code in your controller.
      #
      #   <% form_for :attachment, :html => { :multipart => true } do |f| -%>
      #     <p><%= f.file_field :uploaded_data %></p>
      #     <p><%= submit_tag :Save %>
      #   <% end -%>
      #
      #   @attachment = Attachment.create! params[:attachment]
      #
      # TODO: Allow it to work with Merb tempfiles too.
      def uploaded_data=(file_data)
        if file_data.respond_to?(:content_type)
          return nil if file_data.size == 0
          self.content_type = file_data.content_type
          self.filename     = file_data.original_filename if respond_to?(:filename)
        else
          return nil if file_data.blank? || file_data['size'] == 0
          self.content_type = file_data['content_type']
          self.filename =  file_data['filename']
          file_data = file_data['tempfile']
        end
        if file_data.is_a?(StringIO)
          file_data.rewind
          set_temp_data file_data.read
        else
          self.temp_paths.unshift file_data
        end
      end

      # Gets the latest temp path from the collection of temp paths.  While working with an attachment,
      # multiple Tempfile objects may be created for various processing purposes (resizing, for example).
      # An array of all the tempfile objects is stored so that the Tempfile instance is held on to until
      # it's not needed anymore.  The collection is cleared after saving the attachment.
      def temp_path
        p = temp_paths.first
        p.respond_to?(:path) ? p.path : p.to_s
      end

      # Gets an array of the currently used temp paths.  Defaults to a copy of #full_filename.
      def temp_paths
        @temp_paths ||= (new_record? || !respond_to?(:full_filename) || !File.exist?(full_filename) ?
          [] : [copy_to_temp_file(full_filename)])
      end

      # Gets the data from the latest temp file.  This will read the file into memory.
      def temp_data
        save_attachment? ? File.read(temp_path) : nil
      end

      # Writes the given data to a Tempfile and adds it to the collection of temp files.
      def set_temp_data(data)
        temp_paths.unshift write_to_temp_file data unless data.nil?
      end

      # Copies the given file to a randomly named Tempfile.
      def copy_to_temp_file(file)
        self.class.copy_to_temp_file file, random_tempfile_filename
      end

      # Writes the given file to a randomly named Tempfile.
      def write_to_temp_file(data)
        self.class.write_to_temp_file data, random_tempfile_filename
      end

      # Stub for creating a temp file from the attachment data.  This should be defined in the backend module.
      def create_temp_file() end

      # Allows you to work with a processed representation (RMagick, ImageScience, etc) of the attachment in a block.
      #
      #   @attachment.with_image do |img|
      #     self.data = img.thumbnail(100, 100).to_blob
      #   end
      #
      def with_image(&block)
        self.class.with_image(temp_path, &block)
      end

      protected
        # Generates a unique filename for a Tempfile.
        def random_tempfile_filename
          "#{rand Time.now.to_i}#{filename || 'attachment'}"
        end

        def sanitize_filename(filename)
          return unless filename
          filename.strip.tap do |name|
            # NOTE: File.basename doesn't work right with Windows paths on Unix
            # get only the filename, not the whole path
            name.gsub!(/^.*(\\|\/)/, '')

            # Finally, replace all non alphanumeric, underscore or periods with underscore
            name.gsub!(/[^A-Za-z0-9\.\-]/, '_')
          end
        end

        # before_validation callback.
        def set_size_from_temp_path
          self.size = File.size(temp_path) if save_attachment?
        end

        # validates the size and content_type attributes according to the current model's options
        def attachment_attributes_valid?
          [:size, :content_type].each do |attr_name|
            enum = attachment_options[attr_name]
            if Object.const_defined?(:I18n) # Rails >= 2.2
              errors.add attr_name, I18n.translate("activerecord.errors.messages.inclusion", attr_name => enum) unless enum.nil? || enum.include?(send(attr_name))
            else
              errors.add attr_name, ActiveRecord::Errors.default_error_messages[:inclusion] unless enum.nil? || enum.include?(send(attr_name))
            end
          end
        end

        # Initializes a new thumbnail with the given suffix.
        def find_or_initialize_thumbnail(file_name_suffix)
          respond_to?(:parent_id) ?
            thumbnail_class.find_or_initialize_by_thumbnail_and_parent_id(file_name_suffix.to_s, id) :
            thumbnail_class.find_or_initialize_by_thumbnail(file_name_suffix.to_s)
        end

        # Stub for a #process_attachment method in a processor
        def process_attachment
          @saved_attachment = save_attachment?
        end

        # Cleans up after processing.  Thumbnails are created, the attachment is stored to the backend, and the temp_paths are cleared.
        def after_process_attachment
          if @saved_attachment
            if respond_to?(:process_attachment_with_processing) && thumbnailable? && !attachment_options[:thumbnails].blank? && parent_id.nil?
              temp_file = temp_path || create_temp_file
              attachment_options[:thumbnails].each { |suffix, size| create_or_update_thumbnail(temp_file, suffix, *size) }
            end
            save_to_storage
            @temp_paths.clear
            @saved_attachment = nil
          end
        end

        # Resizes the given processed img object with either the attachment resize options or the thumbnail resize options.
        def resize_image_or_thumbnail!(img)
          if (!respond_to?(:parent_id) || parent_id.nil?) && attachment_options[:resize_to] # parent image
            resize_image(img, attachment_options[:resize_to])
          elsif thumbnail_resize_options # thumbnail
            resize_image(img, thumbnail_resize_options)
          end
        end

        if defined?(Rails) && Rails::VERSION::MAJOR >= 3
          def callback_with_args(method, arg = self)
            send(method, arg) if respond_to?(method)
          end
        # Yanked from ActiveRecord::Callbacks, modified so I can pass args to the callbacks besides self.
        # Only accept blocks, however
        elsif ActiveSupport.const_defined?(:Callbacks)
          # Rails 2.1 and beyond!
          def callback_with_args(method, arg = self)
            notify(method)

            result = run_callbacks(method, { :object => arg }) { |result, object| result == false }

            if result != false && respond_to_without_attributes?(method)
              result = send(method)
            end

            result
          end

          def run_callbacks(kind, options = {}, &block)
            options.reverse_merge!( :object => self )
            self.class.send("#{kind}_callback_chain").run(options[:object], options, &block)
          end
        else
          # Rails 2.0
          def callback_with_args(method, arg = self)
            notify(method)

            result = nil
            callbacks_for(method).each do |callback|
              result = callback.call(self, arg)
              return false if result == false
            end
            result
          end
        end

        # Removes the thumbnails for the attachment, if it has any
        def destroy_thumbnails
          self.thumbnails.each { |thumbnail| thumbnail.destroy } if thumbnailable?
        end
    end
  end
end
