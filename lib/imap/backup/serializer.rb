require "forwardable"

require "email/mboxrd/message"
require "imap/backup/serializer/appender"
require "imap/backup/serializer/imap"
require "imap/backup/serializer/message"
require "imap/backup/serializer/mbox"
require "imap/backup/serializer/message_enumerator"
require "imap/backup/serializer/version2_migrator"
require "imap/backup/serializer/unused_name_finder"

module Imap::Backup
  class Serializer
    def self.folder_path_for(path:, folder:)
      relative = File.join(path, folder)
      File.expand_path(relative)
    end

    extend Forwardable

    def_delegator :mbox, :pathname, :mbox_pathname
    def_delegators :imap, :get, :messages, :uid_validity, :uids, :update_uid

    attr_reader :folder
    attr_reader :path

    def initialize(path, folder)
      @path = path
      @folder = folder
    end

    # Returns true if there are existing, valid files
    # false otherwise (in which case any existing files are deleted)
    def validate!
      optionally_migrate2to3

      return true if imap.valid? && mbox.valid?

      delete

      false
    end

    def delete
      imap.delete
      @imap = nil
      mbox.delete
      @mbox = nil
    end

    def apply_uid_validity(value)
      validate!

      case
      when uid_validity.nil?
        internal_force_uid_validity(value)
        nil
      when uid_validity == value
        # NOOP
        nil
      else
        apply_new_uid_validity value
      end
    end

    def force_uid_validity(value)
      validate!

      internal_force_uid_validity(value)
    end

    def append(uid, message, flags)
      validate!

      appender = Serializer::Appender.new(folder: folder, imap: imap, mbox: mbox)
      appender.run(uid: uid, message: message, flags: flags)
    end

    def update(uid, flags: nil)
      message = imap.get(uid)
      return if !message

      message.flags = flags if flags
      imap.save
    end

    def each_message(required_uids = nil, &block)
      required_uids ||= uids

      validate!

      return enum_for(:each_message, required_uids) if !block

      enumerator = Serializer::MessageEnumerator.new(imap: imap)
      enumerator.run(uids: required_uids, &block)
    end

    def filter(&block)
      temp_name = Serializer::UnusedNameFinder.new(serializer: self).run
      temp_folder_path = self.class.folder_path_for(path: path, folder: temp_name)
      new_mbox = Serializer::Mbox.new(temp_folder_path)
      new_imap = Serializer::Imap.new(temp_folder_path)
      new_imap.uid_validity = imap.uid_validity
      appender = Serializer::Appender.new(folder: temp_name, imap: new_imap, mbox: new_mbox)
      enumerator = Serializer::MessageEnumerator.new(imap: imap)
      enumerator.run(uids: uids) do |message|
        keep = block.call(message)
        appender.run(uid: message.uid, message: message.body, flags: message.flags) if keep
      end
      imap.delete
      new_imap.rename imap.folder_path
      mbox.delete
      new_mbox.rename mbox.folder_path
      @imap = nil
      @mbox = nil
    end

    def folder_path
      self.class.folder_path_for(path: path, folder: folder)
    end

    private

    def rename(new_name)
      destination = self.class.folder_path_for(path: path, folder: new_name)
      ensure_containing_directory(new_name)
      mbox.rename destination
      imap.rename destination
    end

    def internal_force_uid_validity(value)
      imap.uid_validity = value
      mbox.touch
    end

    def mbox
      @mbox ||=
        begin
          ensure_containing_directory(folder)
          Serializer::Mbox.new(folder_path)
        end
    end

    def imap
      @imap ||=
        begin
          ensure_containing_directory(folder)
          Serializer::Imap.new(folder_path)
        end
    end

    def optionally_migrate2to3
      migrator = Version2Migrator.new(folder_path)
      return if !migrator.required?

      Logger.logger.info <<~MESSAGE
        Local metadata for folder '#{folder_path}' is currently stored in the version 2 format.

        This will now be transformed into the version 3 format.
      MESSAGE

      migrator.run
    end

    def ensure_containing_directory(folder)
      relative = File.dirname(folder)
      directory = Serializer::Directory.new(path, relative)
      directory.ensure_exists
    end

    def apply_new_uid_validity(value)
      new_name = rename_existing_folder
      # Clear memoization so we get empty data
      @mbox = nil
      @imap = nil
      internal_force_uid_validity(value)

      new_name
    end

    def rename_existing_folder
      new_name = Serializer::UnusedNameFinder.new(serializer: self).run
      rename new_name
      new_name
    end
  end
end
