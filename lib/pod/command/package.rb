require 'tmpdir'
module Pod
  class Command
    class Package < Command
      self.summary = 'Package a podspec into a static library.'
      self.arguments = [
        CLAide::Argument.new('NAME', true),
        CLAide::Argument.new('SOURCE', false)
      ]

      def self.options
        [
          ['--force',     'Overwrite existing files.'],
          ['--no-mangle', 'Do not mangle symbols of depedendant Pods.'],
          ['--embedded',  'Generate embedded frameworks.'],
          ['--library',   'Generate static libraries.'],
          ['--dynamic',   'Generate dynamic framework.'],
          ['--local',     'Use local state rather than published versions.'],
          ['--bundle-identifier', 'Bundle identifier for dynamic framework'],
          ['--exclude-deps', 'Exclude symbols from dependencies.'],
          ['--configuration', 'Build the specified configuration (e.g. Debug). Defaults to Release'],
          ['--subspecs', 'Only include the given subspecs'],
          ['--spec-sources=private,https://github.com/CocoaPods/Specs.git', 'The sources to pull dependent ' \
            'pods from (defaults to https://github.com/CocoaPods/Specs.git)']
        ]
      end

      def initialize(argv)
        @embedded = argv.flag?('embedded')
        @library = argv.flag?('library')
        @dynamic = argv.flag?('dynamic')
        @local = argv.flag?('local', false)
        @package_type = if @embedded
                          :static_framework
                        elsif @dynamic
                          :dynamic_framework
                        elsif @library
                          :static_library
                        else
                          :static_framework
                        end
        @force = argv.flag?('force')
        @mangle = argv.flag?('mangle', true)
        @bundle_identifier = argv.option('bundle-identifier', nil)
        @exclude_deps = argv.flag?('exclude-deps', false)
        @name = argv.shift_argument
        @source = argv.shift_argument
        @spec_sources = argv.option('spec-sources', 'https://github.com/CocoaPods/Specs.git').split(',')

        subspecs = argv.option('subspecs')
        @subspecs = subspecs.split(',') unless subspecs.nil?

        @config = argv.option('configuration', 'Release')

        @source_dir = Dir.pwd # 执行命令时所在目录
        @is_spec_from_path = false
        @spec = spec_with_path(@name)
        @is_spec_from_path = true if @spec
        @spec ||= spec_with_name(@name)
        super
      end

      # 校验所传参数有效性，如果参数中带有 --help 选项，则会直接抛出帮助提示, 在 run 方法执行前被调用
      def validate!
        super
        help! 'A podspec name or path is required.' unless @spec
        help! 'podspec has binary-only depedencies, mangling not possible.' if @mangle && binary_only?(@spec)
        help! '--bundle-identifier option can only be used for dynamic frameworks' if @bundle_identifier && !@dynamic
        help! '--exclude-deps option can only be used for static libraries' if @exclude_deps && @dynamic
        help! '--local option can only be used when a local `.podspec` path is given.' if @local && !@is_spec_from_path
      end

      # 入口, 检查是否取到所要编译的 podspec 文件。然后针对它创建对应的 working_directory 和 target_directory
      def run
        # 检查是否取到所要编译的 podspec 文件
        if @spec.nil?
          help! "Unable to find a podspec with path or name `#{@name}`."
          return
        end

        # working_directory 为打包所在的临时目录
        # target_directory 为最终生成 package 的所在目录
        target_dir, work_dir = create_working_directory
        return if target_dir.nil?

        build_package

        # 编译产物 copy 到 target_directory
        `mv "#{work_dir}" "#{target_dir}"`
        # 切换回最初执行命令所在目录
        Dir.chdir(@source_dir)
      end

      private

      # iOS / Mac / Watch
      def build_in_sandbox(platform)
        config.installation_root  = Pathname.new(Dir.pwd) # config 的安装目录 working_dirctory
        config.sandbox_root       = 'Pods' # 沙盒目录 ./Pods

        static_sandbox = build_static_sandbox(@dynamic) # 创建沙盒 -> pod_utils.rb
        static_installer = install_pod(platform.name, static_sandbox) # pod install -> pod_utils.rb

        if @dynamic
          dynamic_sandbox = build_dynamic_sandbox(static_sandbox, static_installer)
          install_dynamic_pod(dynamic_sandbox, static_sandbox, static_installer, platform)
        end

        begin
          perform_build(platform, static_sandbox, dynamic_sandbox, static_installer)
        ensure # in case the build fails; see Builder#xcodebuild.
          Pathname.new(config.sandbox_root).rmtree
          FileUtils.rm_f('Podfile.lock')
        end
      end

      def build_package
        # SpecBuilder用于生成描述最终产物的 podspec 文件, SpecBuilder 就是一个模版文件生成器
        builder = SpecBuilder.new(@spec, @source, @embedded, @dynamic)
        # bundler 调用 spec_metadata 方法遍历指定的 podspec 文件复刻出对应的配置并返回新生成的 podspec 文件
        newspec = builder.spec_metadata

        @spec.available_platforms.each do |platform|
          build_in_sandbox(platform) # iOS / Mac / Watch 依次执行 build_in_sandbox
          # 同时将 platform 信息写入 newspec
          # s.ios.deployment_target    = '8.0'
          # s.ios.vendored_framework   = 'ios/A.embeddedframework/A.framework'
          newspec += builder.spec_platform(platform)
        end

        # 将 podspec 写入 target_directory 编译结束
        newspec += builder.spec_close
        File.open(@spec.name + '.podspec', 'w') { |file| file.write(newspec) }
      end

      def create_target_directory
        target_dir = "#{@source_dir}/#{@spec.name}-#{@spec.version}"
        if File.exist? target_dir
          if @force
            Pathname.new(target_dir).rmtree
          else
            UI.puts "Target directory '#{target_dir}' already exists."
            return nil
          end
        end
        target_dir
      end

      def create_working_directory
        target_dir = create_target_directory
        return if target_dir.nil?

        work_dir = Dir.tmpdir + '/cocoapods-' + Array.new(8) { rand(36).to_s(36) }.join
        Pathname.new(work_dir).mkdir
        Dir.chdir(work_dir)

        [target_dir, work_dir]
      end

      def perform_build(platform, static_sandbox, dynamic_sandbox, static_installer)
        static_sandbox_root = config.sandbox_root.to_s

        if @dynamic
          static_sandbox_root = "#{static_sandbox_root}/#{static_sandbox.root.to_s.split('/').last}"
          dynamic_sandbox_root = "#{config.sandbox_root}/#{dynamic_sandbox.root.to_s.split('/').last}"
        end

        builder = Pod::Builder.new(
          platform,
          static_installer,
          @source_dir,
          static_sandbox_root,
          dynamic_sandbox_root,
          static_sandbox.public_headers.root,
          @spec,
          @embedded,
          @mangle,
          @dynamic,
          @config,
          @bundle_identifier,
          @exclude_deps
        )

        builder.build(@package_type)

        return unless @embedded
        builder.link_embedded_resources
      end
    end
  end
end
