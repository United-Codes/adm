-- Settings of the course "Extract data from PDF forms".
-- Every script of the course that needs a value runs this file first. Change the values here, once.

-- The ADM user that owns the course folders and acts in the scripts. It must be an ADM administrator
-- with a home folder in ADM.
define pfx_user = ADMIN

-- The provider of the models, as UC AI names it: openai, anthropic, google, mistral, ollama, ...
define pfx_provider = openai
-- The model that reads the text of a PDF, and the model that reads images (lesson 4).
define pfx_text_model = 'gpt-5.6-luna'
define pfx_vision_model = 'gpt-5.6-luna'
-- Static ID of the APEX web credential that holds the API key of the provider. For Ollama without
-- authentication, leave it empty.
define pfx_credential = 'OPENAI'
-- Only for the provider ollama: the base URL of the Ollama API, without /chat at the end.
define pfx_base_url = 'http://localhost:11434/api'
-- The models that lesson 4 compares, separated by commas. Every model must read text and images.
define pfx_compare_models = 'gpt-5.6-luna,gpt-5-mini'

-- Only for lesson 4, the section about OCR: the OCR service, as ADM names it: mistral, oci or ollama.
-- Empty by default: no OCR service fits every installation. 04_try_ocr.sql stops when it is empty.
define pfx_ocr_provider = ''
-- The OCR model (ollama only), the static ID of the APEX web credential, and the server address of
-- the service. Leave a value empty if the service does not need it.
define pfx_ocr_model = ''
define pfx_ocr_credential = ''
define pfx_ocr_base_url = ''

-- The home folder of pfx_user in ADM, for example /users/admin. Do not change the lines below.
set define on
set termout off
column pfx_home new_value pfx_home noprint
select '/users/' || lower('&pfx_user') as pfx_home from dual;

-- The config object of the models: what the profile passes on to UC AI. The provider ollama needs
-- the base URL and the options of the request. Other providers need only the credential.
column pfx_model_config new_value pfx_model_config noprint format a600
select case lower('&pfx_provider')
         when 'ollama'
         then '{"g_base_url": "&pfx_base_url", "g_apex_web_credential": "&pfx_credential", '
           || '"g_extra_body": {"options": {"temperature": 0, "num_ctx": 16384}}, '
           || '"ollama": {"g_use_responses_api": false}}'
         else '{"g_apex_web_credential": "&pfx_credential"}'
       end as pfx_model_config
  from dual;
set termout on
