require 'cocoapods-core/specification/consumer'
require 'cocoapods-core/specification/dsl'
require 'cocoapods-core/specification/linter'
require 'cocoapods-core/specification/root_attribute_accessors'
require 'cocoapods-core/specification/set'
require 'cocoapods-core/specification/yaml'

module Pod

  # The Specification provides a DSL to describe a Pod. A pod is defined as a
  # library originating from a source. A specification can support detailed
  # attributes for modules of code  through subspecs.
  #
  # Usually it is stored in files with `podspec` extension.
  #
  class Specification

    include Pod::Specification::DSL
    include Pod::Specification::DSL::Deprecations
    include Pod::Specification::RootAttributesAccessors
    include Pod::Specification::YAMLSupport

    # @return [Specification] the parent of the specification unless the
    #         specification is a root.
    #
    attr_reader :parent

    # @param  [Specification] parent @see parent
    #
    # @param  [String] name
    #         the name of the specification.
    #
    def initialize(parent = nil, name = nil)
      @attributes_hash = {}
      @subspecs = []
      @parent = parent
      attributes_hash['name'] = name

      yield self if block_given?
    end

    # @return [Hash] the hash that stores the information of the attributes of
    #         the specification.
    #
    attr_accessor :attributes_hash

    # @return [Array<Specification>] The subspecs of the specification.
    #
    attr_accessor :subspecs

    # Checks if a specification si equal to the given one.
    #
    # @param  [Specification] other
    #         the specification to compare with.
    #
    # @return [Bool] whether the specifications are equal.
    #
    def ==(other)
      self.class === other &&
        attributes_hash == other.attributes_hash &&
        subspecs == other.subspecs &&
        pre_install_callback == other.pre_install_callback &&
        post_install_callback == other.post_install_callback
    end

    # @return [String] A string suitable for representing the specification in
    #         clients.
    #
    def to_s
      "#{name} (#{version})"
    end

    # @return [String] A string suitable for debugging.
    #
    def inspect
      "#<#{self.class.name} name=#{name.inspect}>"
    end

    # @param    [String] string_representation
    #           the string that describes a {Specification} generated from
    #           {Specification#to_s}.
    #
    # @example  Input examples
    #
    #           "libPusher (1.0)"
    #           "libPusher (HEAD based on 1.0)"
    #           "RestKit/JSON (1.0)"
    #
    # @return   [Array<String, Version>] the name and the version of a
    #           pod.
    #
    def self.name_and_version_from_string(string_reppresenation)
      match_data = string_reppresenation.match(/(\S*) \((.*)\)/)
      name = match_data[1]
      vers = Version.new(match_data[2])
      [name, vers]
    end

    # Returns the root name of a specification.
    #
    # @param  [String] the name of a specification or of a subspec.
    #
    # @return [String] the root name
    #
    def self.root_name(full_name)
      full_name.split('/').first
    end

    #-------------------------------------------------------------------------#

    public

    # @!group Hierarchy

    # @return [Specification] The root specification or itself if it is root.
    #
    def root
      parent ? parent.root : self
    end

    # @return [Bool] whether the specification is root.
    #
    def root?
      parent.nil?
    end

    # @return [Bool] whether the specification is a subspec.
    #
    def subspec?
      !parent.nil?
    end

    #-------------------------------------------------------------------------#

    public

    # @!group Dependencies & Subspecs

    # @return [Array<Specifications>] the recursive list of all the subspecs of
    #         a specification.
    #
    def recursive_subspecs
      mapper = lambda do |spec|
        spec.subspecs.map do |subspec|
          [subspec, *mapper.call(subspec)]
        end.flatten
      end
      mapper.call(self)
    end

    # Returns the subspec with the given name or the receiver if the name is
    # nil or equal to the name of the receiver.
    #
    # @param    [String] relative_name
    #           the relative name of the subspecs starting from the receiver
    #           including the name of the receiver.
    #
    # @example  Retrieving a subspec
    #
    #           s.subspec_by_name('Pod/subspec').name #=> 'subspec'
    #
    # @return   [Specification] the subspec with the given name or self.
    #
    def subspec_by_name(relative_name)
      if relative_name.nil? || relative_name == base_name
        self
      else
        remainder = relative_name[base_name.size+1..-1]
        subspec_name = remainder.split('/').shift
        subspec = subspecs.find { |s| s.name == "#{self.name}/#{subspec_name}" }
        unless subspec
          raise StandardError, "Unable to find a specification named " \
            "`#{relative_name}` in `#{self.name}`."
        end
        subspec.subspec_by_name(remainder)
      end
    end

    # @return [String] the name of the default subspec if provided.
    #
    def default_subspec
      attributes_hash["default_subspec"]
    end

    # Returns the dependencies on subspecs.
    #
    # @note   A specification has a dependency on either the
    #         {#default_subspec} or each of its children subspecs that are
    #         compatible with its platform.
    #
    # @return [Array<Dependency>] the dependencies on subspecs.
    #
    def subspec_dependencies(platform = nil)
      if default_subspec
        specs = [subspec_by_name("#{name}/#{default_subspec}")]
      else
        specs = subspecs.compact
      end
      if platform
        specs = specs.select { |s| s.supported_on_platform?(platform) }
      end
      specs = specs.map { |s| Dependency.new(s.name, version) }
    end

    # Returns the dependencies on other Pods or subspecs of other Pods.
    #
    # @param  [Bool] all_platforms
    #         whether the dependencies should be returned for all platforms
    #         instead of the active one.
    #
    # @note   External dependencies are inherited by subspecs
    #
    # @return [Array<Dependency>] the dependencies on other Pods.
    #
    def dependencies(platform = nil)
      if platform
        Consumer.new(self, platform).dependencies || []
      else
        available_platforms.map do |platform|
          Consumer.new(self, platform.name).dependencies
        end.flatten.uniq
      end
    end

    # @return [Array<Dependency>] all the dependencies of the specification.
    #
    def all_dependencies(platform = nil)
      dependencies(platform) + subspec_dependencies(platform)
    end

    #-------------------------------------------------------------------------#

    public

    # @!group DSL helpers

    # @return [Bool] whether the specification should use a directory as it
    #         source.
    #
    def local?
      !source.nil? && !source[:local].nil?
    end

    # @return     [Bool] whether the specification is supported in the given
    #             platform.
    #
    # @overload   supported_on_platform?(platform)
    #
    #   @param    [Platform] platform
    #             the platform which is checked for support.
    #
    # @overload   supported_on_platform?(symbolic_name, deployment_target)
    #
    #   @param    [Symbol] symbolic_name
    #             the name of the platform which is checked for support.
    #
    #   @param    [String] deployment_target
    #             the deployment target which is checked for support.
    #
    def supported_on_platform?(*platform)
      platform = Platform.new(*platform)
      available_platforms.any? { |available| platform.supports?(available) }
    end

    # @return [Array<Platform>] The platforms that the Pod is supported on.
    #
    # @note   If no platform is specified, this method returns all known
    #         platforms.
    #
    def available_platforms
      names = supported_platform_names || PLATFORMS
      [*names].map { |name| Platform.new(name, deployment_target(name)) }
    end

    # Returns the deployment target for the specified platform.
    #
    # @param  [String] platform_name
    #         the symbolic name of the platform.
    #
    # @return [String] the deployment target
    # @return [Nil] if not deployment target was specified for the platform.
    #
    def deployment_target(platform_name)
      if attributes_hash[platform_name.to_s]
        result = attributes_hash[platform_name.to_s]["deployment_target"]
      end
      result ||= parent.deployment_target(platform_name) if parent
      result
    end

    protected

    # @return [Symbol] the symbolic name of the platform in which the
    #         specification is supported.
    #
    # @return [Nil] if the specification is supported on all the known
    #         platforms.
    #
    def supported_platform_names
      result = attributes_hash["platform"]
      result ||= parent.supported_platform_names if parent
      result
    end

    #-------------------------------------------------------------------------#

    public

    # @!group Hooks support

    # @return [Proc] the pre install callback if defined.
    #
    attr_reader :pre_install_callback

    # @return [Proc] the post install callback if defined.
    #
    attr_reader :post_install_callback

    # Calls the pre install callback if defined.
    #
    # @param  [Pod::LocalPod] pod
    #         the local pod instance that manages the files described by this
    #         specification.
    #
    # @param  [Podfile::TargetDefinition] target_definition
    #         the target definition that required this specification as a
    #         dependency.
    #
    # @return [Bool] whether a pre install callback was specified and it was
    #         called.
    #
    def pre_install!(pod, target_definition)
      return false unless @pre_install_callback
      @pre_install_callback.call(pod, target_definition)
      true
    end

    # Calls the post install callback if defined.
    #
    # @param  [Pod::TargetInstaller] target_installer
    #         the target installer that is performing the installation of the
    #         pod.
    #
    # @return [Bool] whether a post install callback was specified and it was
    #         called.
    #
    def post_install!(target_installer)
      return false unless @post_install_callback
      @post_install_callback.call(target_installer)
      true
    end

    #-------------------------------------------------------------------------#

    public

    # @!group DSL attribute writers

    # Sets the value for the attribute with the given name.
    #
    # @param  [Symbol] name
    #         the name of the attribute.
    #
    # @param  [Object] value
    #         the value to store.
    #
    # @param  [Symbol] platform.
    #         If provided the attribute is stored only for the given platform.
    #
    # @note   If the provides value is Hash the keys are converted to a string.
    #
    # @return void
    #
    def store_attribute(name, value, platform_name = nil)
      name = name.to_s
      value = convert_keys_to_string(value) if value.is_a?(Hash)
      if platform_name
        platform_name = platform_name.to_s
        attributes_hash[platform_name] ||= {}
        attributes_hash[platform_name][name] = value
      else
        attributes_hash[name] = value
      end
    end

    # Defines the setters methods for the attributes providing support for the
    # Ruby DSL.
    #
    DSL.attributes.values.each do |a|
      define_method(a.writer_name) do |value|
        store_attribute(a.name, value)
      end

      if a.writer_singular_form
        alias_method(a.writer_singular_form, a.writer_name)
      end
    end

    private

    # Converts the keys of the given hash to a string.
    #
    # @param  [Object] value
    #         the value that needs to be stripped from the Symbols.
    #
    # @return [Hash] the hash with the strings instead of the keys.
    #
    def convert_keys_to_string(value)
      return unless value
      result = {}
      value.each do |key, subvalue|
        subvalue = convert_keys_to_string(subvalue) if subvalue.is_a?(Hash)
        result[key.to_s] = subvalue
      end
      result
    end

    #-------------------------------------------------------------------------#

    public

    # @!group File representation

    # @return [String] The SHA1 digest of the file in which the specification
    #         is defined.
    #
    # @return [Nil] If the specification is not defined in a file.
    #
    def checksum
      require 'digest'
      unless defined_in_file.nil?
        checksum = Digest::SHA1.hexdigest(File.read(defined_in_file))
        checksum = checksum.encode('UTF-8') if checksum.respond_to?(:encode)
        checksum
      end
    end

    # @return [String] the path where the specification is defined, if loaded
    #         from a file.
    #
    def defined_in_file
      root? ? @defined_in_file : root.defined_in_file
    end

    # Loads a specification form the given path.
    #
    # @param  [Pathname, String] path
    #         the path of the `podspec` file.
    #
    # @param  [String] subspec_name
    #         the name of the specification that should be returned. If it is
    #         nil returns the root specification.
    #
    # @raise  If the file doesn't return a Pods::Specification after
    #         evaluation.
    #
    # @return [Specification]
    #
    def self.from_file(path, subspec_name = nil)
      path = Pathname.new(path)
      unless path.exist?
        raise StandardError, "No podspec exists at path `#{path}`."
      end
      spec = ::Pod._eval_podspec(path)
      unless spec.is_a?(Specification)
        raise StandardError, "Invalid podspec file at path `#{path}`."
      end
      spec.defined_in_file = path
      spec.subspec_by_name(subspec_name)
    end

    # Sets the path of the `podspec` file used to load the specification.
    #
    # @param  [String] file
    #         the `podspec` file.
    #
    # @return [void]
    #
    # @visibility private
    #
    def defined_in_file=(file)
      unless root?
        raise StandardError, "Defined in file can be set only for root specs."
      end
      @defined_in_file = file
    end
  end


  #---------------------------------------------------------------------------#

  Spec = Specification

  # Evaluates the file at the given path in the namespace of the Pod module.
  #
  # @return [Object] it can return any object but, is expected to be called on
  #         `podspec` files that should return a #{Specification}.
  #
  # @private
  #
  def self._eval_podspec(path)
    string = File.open(path, 'r:utf-8')  { |f| f.read }
    # Work around for Rubinius incomplete encoding in 1.9 mode
    if string.respond_to?(:encoding) && string.encoding.name != "UTF-8"
      string.encode!('UTF-8')
    end

    begin
      eval(string, nil, path.to_s)
    rescue Exception => e
      raise DSLError.new("Invalid `#{path.basename}` file: #{e.message}",
                         path, e.backtrace)
    end
  end
end
