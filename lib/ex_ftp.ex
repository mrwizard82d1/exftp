defmodule ExFtp do
  @doc """
  Open connection to ftp by passing hostname, user and password.
  Returns the pid that has to be passed to execute commands on that connection
  """
  def open(host, user, password, options \\ [])
  def open(host, user, password, [mode: :sftp]) do
    :ok = :ssh.start()
    {:ok, channel_pid, connection} = :ssh_sftp.start_channel(s_to_l(host), [user: s_to_l(user), password: s_to_l(password), silently_accept_hosts: true])
    {:sftp, channel_pid, connection}
  end
  def open(host, user, password, options) do
    :inets.start
    {:ok, pid} = :inets.start(:ftpc, Keyword.merge(options, [host: host |> String.to_charlist]))
    :ok = :ftp.user(pid, user |> String.to_charlist, password |> String.to_charlist)
    {:ftp, pid}
  end


  @doc """
  close the connection
  """
  def close({:sftp, channel, conn}) do
    :ok = :ssh_sftp.stop_channel(channel)
    :ok = :ssh.close(conn)
  end
  def close({:ftp, pid}) do
    :inets.stop(:ftpc, pid)
  end

  defp s_to_l(s) do
    s |> String.to_charlist
  end


  @doc """
  returns the current working directory
  """
  def pwd({:ftp, pid}) do
    {:ok, path} = :ftp.pwd(pid)
    path |> List.to_string
  end
  def pwd({:sftp, _, _}) do
    raise "pwd for sftp not implemented"
  end

  @doc """
  change directory
  """
  def cd(conn, path, create_if_not_exists \\ false)
  def cd({:ftp, pid} = conn, path, create_if_not_exists) do
    if create_if_not_exists do
      ensure_dir(conn, path)
    end
    :ftp.cd(pid, path |> String.to_charlist)
    |> case do
      {:error, :epath} -> {:error, "cant cd to #{path}, dir does not exist"}
      whatelse -> whatelse
    end
  end
  def cd({:sftp, _connection_ref, _pid}, path, create_if_not_exists) do
    raise "cd for sftp not implemented"
  end

  def ensure_dir({:ftp, _pid} = conn, dir) when is_binary(dir) do
    parts = dir |> String.split("/") |> Enum.filter(&(&1 != "")) |> Enum.reverse
    ensure_dir(conn, parts)
  end

  def ensure_dir({:ftp, pid} = conn, dir) when is_list(dir) do
    [leaf | parent] = dir

    if length(parent) > 0 do
      ensure_dir(conn, parent)
    end
    cd(conn, list_to_dir(dir))
    |> case do
      :ok ->
        :ok
      {:error, _} ->
        :ok = mkdir(conn, list_to_dir(dir))
    end
  end

  defp list_to_dir(list) do
    base =
      list
      |> Enum.reverse
      |> Enum.join("/")

    ("/" <> base)
  end


  @doc """
  create directory
  """
  def mkdir({:ftp, pid}, path) do
    :ftp.mkdir(pid, path |> String.to_charlist)
  end
  def mkdir({:sftp, _, pid}, path) do
    :ssh_sftp.make_dir(pid, s_to_l(path))
  end

  @doc """
  list files in directory
  will return an list of %{name: filename, type: :directory|:file}
  """
  def ls({:ftp, pid}) do
    {:ok, listing} = :ftp.ls(pid)
    parse_ls(listing |> List.to_string)
  end
  def ls({:sftp, _, pid}) do
    raise "ls without path not implemented in sftp"
  end

  def ls({:ftp, pid}, path) do
    {:ok, listing} = :ftp.ls(pid, s_to_l(path))
    parse_ls(listing |> List.to_string)
  end
  def ls({:sftp, pid, _}, path) do
    {:ok, list} = :ssh_sftp.list_dir(pid, s_to_l(path))
    list
    |> Enum.map(&List.to_string/1)
    |> Enum.filter(&(!&1 in [".", ".."]))
    |> Enum.map(fn e ->
      :ssh_sftp.opendir(pid, s_to_l("#{path}/#{e}"))
      |> case do
        {:ok, handle} ->
          :ssh_sftp.close(pid, handle)
          %{name: e, type: :directory}
        {:error, _} -> %{name: e, type: :file}
      end
    end)
  end


  def is_directory?({:ftp, pid}, path) do
    :ftp.ls(pid)
    |> case do
      {:ok, list} -> true
      _           -> false
    end
  end
  def is_directory?({:sftp, pid, _}, path) do
    :ssh_sftp.list_dir(pid, s_to_l(path))
    |> case do
      {:ok, list} -> true
      _           -> false
    end
  end

  @doc """
  getrieve a file
  will return {:ok, binary} or {:error, reason}
  """
  def get({:ftp, pid}, filename) do
    :ftp.type(pid, :binary)
    result = :ftp.recv_bin(pid, filename |> String.to_charlist)
    :ftp.type(pid, :ascii)
    result
  end

  def get({:sftp, pid, _}, filename) do
    :ssh_sftp.read_file(pid, s_to_l(filename))
  end

  @doc """
  put a file
  will return :ok or {:error, reason}
  """
  def put({:ftp, pid}, binary, filename) do
    :ftp.type(pid, :binary)
    result = :ftp.send_bin(pid, binary, filename |> String.to_charlist)
    :ftp.type(pid, :ascii)
    result
  end



  def parse_ls(raw) do
    raw
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(fn (s) -> (String.length(s) > 0) end)
    |> Enum.map(&parse_ls_line/1)
  end

  def parse_ls_line(line) do
    # Splitting the line returned by the FTP LIST command on whitespace seems to work on both the existing test data
    # and on my (slightly different) test data. Unfortunately, the output of the FTP LIST command is implementation-
    # dependent (see https://stackoverflow.com/questions/11553953/ftp-ls-lt-command-how-does-it-list-the-file-details
    # -for-linux-ftp-and-window and http://cr.yp.to/ftp/list.html). Consequently, I am not very confident that this
    # solution is robust across FTP server implementations.
    case String.split(line, ~r/\s+/, parts: 9) do
      [type_perms, _, _, _, _, _, _, _, name] -> parse_ls_line([line, String.at(type_perms, 0), name], line)
      :true -> parse_ls_line(nil, line)
    end
  end
  def parse_ls_line([_all, type, name], _line) do
    %{
      name: name,
      type: case type do
              "d" -> :directory
              _ -> :file
            end
    }
  end
  def parse_ls_line(nil, line) do
    raise "failed to parse ftp ls line: #{line}"
  end

  def parse_time(timestr) do
    {:ok, datetime} = Timex.parse(timestr, "{YYYY} {Mshort} {D} {h24}:{m}")
    datetime
  end
end
