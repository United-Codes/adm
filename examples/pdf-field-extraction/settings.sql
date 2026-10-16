-- Settings of the course "Extract data from PDF forms with a local model".
-- Every script of the course that needs a value runs this file first. Change the values here, once.

-- The ADM user that owns the course folders and acts in the scripts. It must be an ADM administrator.
define pfx_user = ADMIN

-- Base URL of the Ollama API, without /chat at the end.
define pfx_base_url = 'http://localhost:11434/api'
-- Static ID of an APEX web credential for the Ollama server. Leave it empty for a server without authentication.
define pfx_credential = ''
-- The model that reads the text of a PDF, and the model that reads images (lesson 4).
define pfx_text_model = 'qwen3.5:9b'
define pfx_vision_model = 'qwen3.5:9b'

-- The home folder of pfx_user in ADM, for example /users/admin. Do not change these lines.
set define on
set termout off
column pfx_home new_value pfx_home noprint
select '/users/' || lower('&pfx_user') as pfx_home from dual;
set termout on
