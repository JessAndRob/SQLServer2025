-- =====================================================================
-- Parameters — override these from the deploy script (03-deploy-database.ps1)
-- or run this file in SSMS in sqlcmd mode to use the defaults below.
-- =====================================================================
:setvar DatabaseName        "pwsh-scripts-🤣"
:setvar MasterKeyPassword   "PSConfEU2026!"
:setvar OpenAIEndpoint      "https://snover-ai.openai.azure.com/openai/deployments/text-embedding-3-small/embeddings?api-version=2024-02-01"
:setvar OpenAIURI           "https://snover-ai.openai.azure.com/"
:setvar OpenAIKey           "YOUR_KEY"
:setvar EmbeddingDeployment "text-embedding-3-small"
:setvar EmbeddingApiVersion "2024-02-01"

USE master;
GO

IF DB_ID(N'$(DatabaseName)') IS NULL
    EXEC ('CREATE DATABASE [$(DatabaseName)]');
GO

USE [$(DatabaseName)];
GO

EXEC sp_configure 'external rest endpoint enabled', 1;
RECONFIGURE WITH OVERRIDE;
GO

ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
GO

IF NOT EXISTS (SELECT * FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = N'$(MasterKeyPassword)';
GO

-- External model depends on the credential, so drop it first
IF EXISTS (SELECT * FROM sys.external_models WHERE name = 'EmbeddingModel')
DROP EXTERNAL MODEL EmbeddingModel;
GO

IF EXISTS (SELECT 1 FROM sys.database_scoped_credentials WHERE name = N'$(OpenAIUri)')
    DROP DATABASE SCOPED CREDENTIAL [$(OpenAIUri)];
GO

CREATE DATABASE SCOPED CREDENTIAL [$(OpenAIUri)]
    WITH IDENTITY = 'HTTPEndpointHeaders',
         SECRET   = '{"api-key":"$(OpenAIKey)"}';
GO

CREATE EXTERNAL MODEL EmbeddingModel
WITH ( LOCATION   = '$(OpenAIEndpoint)',
       API_FORMAT = 'Azure OpenAI',
       MODEL_TYPE = EMBEDDINGS,
       MODEL      = '$(EmbeddingDeployment)',
       CREDENTIAL = [$(OpenAIUri)] );
GO

-- Always start from an empty table so re-runs reflect any schema edits and
-- demos begin from a known state. Drop first, then recreate.
DROP TABLE IF EXISTS dbo.CmdletHelp;
GO

CREATE TABLE dbo.CmdletHelp (
    CmdletId      INT IDENTITY PRIMARY KEY,
    Name          NVARCHAR(200),
    ModuleName    NVARCHAR(200),
    Synopsis      NVARCHAR(MAX),
    Description   NVARCHAR(MAX),
    SearchText    NVARCHAR(MAX),     -- what we embed
    Embedding     VECTOR(1536) NULL
);
GO