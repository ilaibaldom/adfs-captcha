// Compile-time mirror of the AD FS external authentication API
// (namespace Microsoft.IdentityServer.Web.Authentication.External, AD FS 2016/2019/2022).
//
// Interfaces the adapter IMPLEMENTS (IAuthenticationAdapter(+Base), IAuthenticationAdapterMetadata,
// IAdapterPresentation, IAdapterPresentationForm) must match the real ones member-for-member and
// in hierarchy, otherwise the CLR refuses to load the adapter type on the AD FS server. Every
// interface here was checked by reflection against C:\Windows\ADFS\Microsoft.IdentityServer.Web.dll
// from a Windows Server 2019 (17763) AD FS farm.

using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Runtime.Serialization;
using System.Security.Claims;

namespace Microsoft.IdentityServer.Web.Authentication.External
{
    // Verified against the real AD FS 2019 assembly (build 17763): the members are split across
    // IAuthenticationAdapterBase and IAuthenticationAdapter. A flat interface compiles fine but the
    // adapter then fails to load on AD FS.
    public interface IAuthenticationAdapterBase
    {
        IAuthenticationAdapterMetadata Metadata { get; }

        void OnAuthenticationPipelineLoad(IAuthenticationMethodConfigData configData);

        void OnAuthenticationPipelineUnload();

        IAdapterPresentation OnError(HttpListenerRequest request, ExternalAuthenticationException ex);

        IAdapterPresentation TryEndAuthentication(IAuthenticationContext context, IProofData proofData, HttpListenerRequest request, out Claim[] claims);
    }

    public interface IAuthenticationAdapter : IAuthenticationAdapterBase
    {
        IAdapterPresentation BeginAuthentication(Claim identityClaim, HttpListenerRequest request, IAuthenticationContext context);

        bool IsAvailableForUser(Claim identityClaim, IAuthenticationContext context);
    }

    public interface IAuthenticationAdapterMetadata
    {
        string AdminName { get; }

        string[] AuthenticationMethods { get; }

        int[] AvailableLcids { get; }

        Dictionary<int, string> Descriptions { get; }

        Dictionary<int, string> FriendlyNames { get; }

        string[] IdentityClaims { get; }

        bool RequiresIdentity { get; }
    }

    public interface IAdapterPresentation
    {
        string GetPageTitle(int lcid);
    }

    public interface IAdapterPresentationForm : IAdapterPresentation
    {
        string GetFormHtml(int lcid);

        string GetFormPreRenderHtml(int lcid);
    }

    public interface IAuthenticationContext
    {
        string ActivityId { get; }

        string ContextId { get; }

        Dictionary<string, object> Data { get; }

        int Lcid { get; }
    }

    public interface IProofData
    {
        Dictionary<string, object> Properties { get; }   // concrete Dictionary in the real assembly
    }

    public interface IAuthenticationMethodConfigData
    {
        Stream Data { get; }
    }

    [Serializable]
    public class ExternalAuthenticationException : Exception
    {
        public ExternalAuthenticationException() { }

        public ExternalAuthenticationException(string message, IAuthenticationContext context)
            : base(message)
        {
            Context = context;
        }

        public ExternalAuthenticationException(string message, Exception innerException, IAuthenticationContext context)
            : base(message, innerException)
        {
            Context = context;
        }

        protected ExternalAuthenticationException(SerializationInfo info, StreamingContext context)
            : base(info, context) { }

        public IAuthenticationContext Context { get; }
    }
}
