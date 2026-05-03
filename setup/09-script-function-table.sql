-- =====================================================================
-- Schema for demo 3 — script-function similarity.
--
-- Override DatabaseName from setup\10-deploy-script-function-table.ps1
-- or run this file in SSMS in sqlcmd mode to use the default below.
-- =====================================================================
:setvar DatabaseName "pwsh-scripts-🤣"

USE [$(DatabaseName)];
GO

-- IDEMPOTENT on purpose: the demo-3 chain is resumable, so re-running the
-- table creation must not wipe rows the loader already populated. Drop
-- the table by hand if you want a clean slate.
IF OBJECT_ID(N'dbo.ScriptFunction', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ScriptFunction (
        FunctionId      INT IDENTITY PRIMARY KEY,
        FilePath        NVARCHAR(500),
        FunctionName    NVARCHAR(200),
        ParamSignature  NVARCHAR(MAX),
        Body            NVARCHAR(MAX),
        DocComment      NVARCHAR(MAX),
        SearchText      NVARCHAR(MAX),     -- what we embed
        Embedding       VECTOR(1536) NULL, -- text-embedding-3-small
        INDEX IX_FunctionName (FunctionName)
    );
END;
GO
