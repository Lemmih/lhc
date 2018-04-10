{-# OPTIONS_GHC -fno-warn-orphans #-}
module Data.Bedrock.PrettyPrint
  ( Pretty(..)
  , module Data.Bedrock.PrettyPrint
  ) where

import           Data.List
import           Language.Haskell.TypeCheck.Pretty
import           Text.PrettyPrint.ANSI.Leijen      (Doc, char, int, text, (<+>),
                                                    (<>))
import qualified Text.PrettyPrint.ANSI.Leijen      as Doc

import           Data.Bedrock

-------------------------------------------------------------------------------
-- Pretty print

instance Pretty Name where
  pretty name =
    text (intercalate "." (nameModule name ++ [nameIdentifier name]))
    <> unique
    where
      unique = if nameUnique name == 0
        then Doc.empty
        else char '^' <> int (nameUnique name)

instance Pretty Type where
  pretty NodePtr        = Doc.char '*'
  pretty Node           = Doc.char '%'
  pretty (StaticNode n) = Doc.char '%' <> Doc.int n <> Doc.char '%'
  pretty IWord          = Doc.char '#'
  pretty (Primitive ty) = pretty ty
  pretty FramePtr       = Doc.red (Doc.char '@')

instance Pretty CType where
  pretty I8 = text "i8"
  pretty I32 = text "i32"
  pretty I64 = text "i64"
  pretty (CPointer ty) = pretty ty <> Doc.char '*'
  pretty (CFunction retTy argTys) =
    pretty retTy <> Doc.parens (ppList (map pretty argTys))
  pretty CVoid = text "void"

instance Pretty NodeDefinition where
  pretty (NodeDefinition name args) =
    text "node" <+> Doc.blue (pretty name) <> Doc.parens (ppList (map pretty args))

instance Pretty Variable where
  pretty Variable{ variableName = name, variableType = Primitive ty } =
    pretty ty <> char '|' <> pretty name
  pretty Variable{ variableName = name, variableType = ty } =
    pretty ty <> pretty name

instance Pretty Literal where
  pretty literal =
    case literal of
      LiteralInt i      -> Doc.integer i
      LiteralString str -> Doc.text (show str)

ppNode :: NodeName -> [Doc] -> Doc
ppNode (ConstructorName constructor blanks) args =
  Doc.hsep (Doc.blue (pretty constructor) : args ++ replicate blanks (Doc.char '_'))
ppNode (FunctionName fn blanks) args =
  Doc.hsep (Doc.magenta (pretty fn) : args ++ replicate blanks (Doc.char '_'))
ppNode UnboxedTupleName args =
  Doc.text "(#" <+> ppList args <+> Doc.text "#)"
--ppNode (CatchFrame fn blanks) args =
--  Doc.hsep (Doc.green (ppName fn) : args ++ replicate blanks (Doc.char '_'))

ppPattern :: Pattern -> Doc
ppPattern pattern =
  case pattern of
    NodePat name binds -> ppNode name (map pretty binds)
    LitPat lit         -> pretty lit
    -- UnboxedPat binds   -> Doc.text "(#" <+> ppList (map pretty binds) <+> Doc.text "#)"
    -- VarPat var         -> pretty var

ppList :: [Doc] -> Doc
ppList = Doc.hsep . Doc.punctuate (Doc.char ',')

ppAlternative :: Alternative -> Doc
ppAlternative (Alternative pattern expression) =
  ppPattern pattern <+> text "→" Doc.<$$>
  Doc.indent 2 (ppBlock expression)

instance Pretty MemAttributes where
  pretty MemAttributes{ memConstant = constant, memAliasGroup = g} =
    if constant then ppSyntax "constant" else Doc.empty <+>
    case g of
      Nothing    -> Doc.empty
      Just group -> ppSyntax "alias" <> Doc.char ':' <> Doc.int group

instance Pretty Expression where
  pretty simple =
    case simple of
      Alloc n ->
        ppSyntax "@alloc" <+> Doc.int n
      Store node args ->
        ppSyntax "@store" <+>
        Doc.parens (ppNode node (map pretty args))
      BumpHeapPtr n ->
        ppSyntax "@bump" <+> Doc.int n
      Write ptr idx var ->
        ppSyntax "@write" <+>
        pretty ptr <> Doc.brackets (Doc.int idx) <+> pretty var
      Address ptr idx ->
        ppSyntax "&" <> pretty ptr <> Doc.brackets (Doc.int idx)
      FunctionPointer fn ->
        ppSyntax "&" <> pretty fn
      Fetch ptr ->
        ppSyntax "@fetch" <+> pretty ptr
      Load ptr nth ->
        ppSyntax "@load" <+> pretty ptr <>
        Doc.brackets (Doc.int nth)
      Add lhs rhs ->
        ppSyntax "@add" <+> pretty lhs <+> pretty rhs
      Undefined ->
        ppSyntax "@undefined"
      Save var n ->
        ppSyntax "@save" <> Doc.brackets (Doc.int n) <+> pretty var
      Restore n ->
        ppSyntax "@restore" <> Doc.brackets (Doc.int n)
      Application fn args ->
        pretty fn <> Doc.parens (ppList $ map pretty args)
      CCall fn args ->
        ppSyntax "@ccall" <+>
        text fn <> Doc.parens (ppList $ map pretty args)
      Catch exh exhArgs fn args ->
        ppSyntax "@catch" <+>
        pretty exh <> Doc.parens (ppList $ map pretty exhArgs) <+>
        pretty fn <> Doc.parens (ppList $ map pretty args)
      TypeCast var ->
        ppSyntax "@cast" <> Doc.parens (pretty var)
      MkNode name vars ->
        ppSyntax "@node" <+> Doc.parens (ppNode name (map pretty vars))
      Literal lit ->
        ppSyntax "@literal" <+> pretty lit
      Eval var ->
        ppSyntax "@eval" <+> pretty var
      Apply a b ->
        ppSyntax "@apply" <+> pretty a <+> pretty b
      ReadRegister reg ->
        ppSyntax "@register" <+> text reg
      WriteRegister reg var ->
        ppSyntax "@register" <+> text reg <+> Doc.equals <+> pretty var
      ReadGlobal reg ->
        ppSyntax "@global" <+> text reg
      WriteGlobal reg var ->
        ppSyntax "@global" <+> text reg <+> Doc.equals <+> pretty var
      GCAllocate n ->
        ppSyntax "@gc_allocate" <+> Doc.int n
      GCBegin ->
        ppSyntax "@gc_begin"
      GCEnd ->
        ppSyntax "@gc_end"
      GCMark var ->
        ppSyntax "@gc_mark" <+> pretty var
      GCMarkNode var ->
        ppSyntax "@gc_mark_node" <+> pretty var

ppBlock :: Block -> Doc
ppBlock block =
  case block of
    Return args ->
      ppSyntax "@return" <+>
      ppList (map pretty args)
    Bind [] simple rest ->
      pretty simple Doc.<$$>
      ppBlock rest
    Bind names simple rest ->
      ppList (map pretty names) <+>
      text "=" <+>
      pretty simple Doc.<$$>
      ppBlock rest
    Case scrut Nothing [(Alternative pattern expression)] ->
      ppPattern pattern <+> text "← " <+> pretty scrut Doc.<$$>
      ppBlock expression
    Case scrut Nothing alts ->
      ppSyntax "case" <+> pretty scrut <+> ppSyntax "of" Doc.<$$>
      Doc.indent 2 (Doc.vsep $ map ppAlternative alts)
    Case scrut (Just branch) alts ->
      ppSyntax "case" <+> pretty scrut <+> ppSyntax "of" Doc.<$$>
      Doc.indent 2 (Doc.vsep (map ppAlternative alts ++
        [text "DEFAULT" <+> text "→" Doc.<$$>
          Doc.indent 2 (ppBlock branch)]))
    Raise obj ->
      ppSyntax "@raise" <+> pretty obj
    TailCall fn args ->
      ppSyntax "@tail" <+>
      pretty fn <> Doc.parens (ppList (map pretty args))
    Invoke cont args ->
      ppSyntax "@invoke" <+> pretty cont <>
      Doc.parens (ppList (map pretty args))
    InvokeHandler cont exception ->
      ppSyntax "@invokeHandler" <>
      Doc.parens (ppList $ map pretty [cont, exception])
    Exit ->
      ppSyntax "@exit"
    Panic msg ->
      ppSyntax "@panic" <+> text (show msg)

ppSyntax :: String -> Doc
ppSyntax = Doc.green . text

ppFnName :: Name -> Doc
ppFnName = Doc.blue . pretty

ppTypes :: [Type] -> Doc
ppTypes []  = text "void"
ppTypes lst = Doc.hsep $ map pretty lst

instance Pretty Attribute where
  pretty NoCPS    = text "NoCPS"
  pretty Internal = text "Internal"

instance Pretty Function where
  pretty fn =
    ppList (map pretty (fnAttributes fn)) Doc.<$$>
    ppTypes (fnResults fn) <+>
    ppFnName (fnName fn) <+> Doc.hsep (map pretty (fnArguments fn)) <+>
    Doc.char '=' Doc.<$$>
    Doc.indent 2 (ppBlock (fnBody fn))

ppEntryPoint :: Name -> Doc
ppEntryPoint entry = text "entrypoint:" <+> pretty entry

instance Pretty Foreign where
  pretty f =
    ppSyntax "foreign" <+> pretty (foreignReturn f) <+>
    text (foreignName f) <>
    Doc.parens (ppList (map pretty $ foreignArguments f))

instance Pretty Module where
  pretty m =
    Doc.vsep (map pretty (modForeigns m)) Doc.<$$>
    Doc.vsep (map pretty (nodes m)) Doc.<$$>
    ppEntryPoint (entryPoint m) Doc.<$$>
    Doc.vsep (map pretty (functions m))
